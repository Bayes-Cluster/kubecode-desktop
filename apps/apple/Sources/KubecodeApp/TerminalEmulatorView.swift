import AppKit
import SwiftUI
@preconcurrency import SwiftTerm
import KubecodeKit

enum TerminalStreamUpdate: Equatable {
    case output(data: String, reset: Bool)
    case status(status: String, exitCode: Int?, signal: String?)
}

struct TerminalStreamState: Equatable {
    private(set) var cursor = 0
    private(set) var status = "running"
    private(set) var exitCode: Int?
    private(set) var signal: String?

    var isExited: Bool { status == "exited" }

    mutating func apply(_ event: TerminalServerEvent) -> TerminalStreamUpdate? {
        switch event.type {
        case "output":
            if let nextCursor = event.cursor { cursor = max(cursor, nextCursor) }
            return .output(data: event.data ?? "", reset: event.truncated == true)
        case "status":
            status = event.status ?? status
            exitCode = event.exitCode
            signal = event.signal
            return .status(status: status, exitCode: exitCode, signal: signal)
        default:
            return nil
        }
    }
}

enum TerminalConnectionPhase: Equatable {
    case connecting
    case connected
    case reconnecting
    case exited
    case failed(String)
}

enum TerminalReconnectPolicy {
    static let maximumAutomaticAttempts = 5

    static func shouldStopAutomatically(after attempt: Int) -> Bool {
        attempt >= maximumAutomaticAttempts
    }

    static func delayMilliseconds(attempt: Int) -> Int {
        min(4_000, 250 * (1 << min(max(attempt - 1, 0), 4)))
    }
}

enum TerminalTransportErrorPolicy {
    static func shouldReport(_ error: Error) -> Bool {
        !isExpectedShutdown(error as NSError, depth: 0)
    }

    private static func isExpectedShutdown(_ error: NSError, depth: Int) -> Bool {
        guard depth < 4 else { return false }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(POSIXErrorCode.ENOTCONN.rawValue) {
            return true
        }
        if error.domain == NSURLErrorDomain,
           error.code == URLError.cancelled.rawValue
            || error.code == URLError.networkConnectionLost.rawValue {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isExpectedShutdown(underlying as NSError, depth: depth + 1)
    }
}

protocol TerminalStreamingConnection: AnyObject, Sendable {
    func events() -> AsyncThrowingStream<TerminalServerEvent, Error>
    func send(input: String) async throws
    func resize(cols: Int, rows: Int) async throws
    func close()
}

extension TerminalConnection: TerminalStreamingConnection {}

@MainActor
final class TerminalRecoveryController {
    typealias ConnectionFactory = (Int) throws -> any TerminalStreamingConnection
    typealias Sleep = (Int) async -> Void

    private let makeConnection: ConnectionFactory
    private let sleep: Sleep
    private let onUpdate: (TerminalStreamUpdate) -> Void
    private let onPhaseChange: (TerminalConnectionPhase) -> Void
    private let onError: (String) -> Void
    private var connection: (any TerminalStreamingConnection)?
    private var eventsTask: Task<Void, Never>?
    private var streamState = TerminalStreamState()
    private var isStopped = true

    init(
        makeConnection: @escaping ConnectionFactory,
        sleep: @escaping Sleep = { milliseconds in
            try? await Task.sleep(for: .milliseconds(milliseconds))
        },
        onUpdate: @escaping (TerminalStreamUpdate) -> Void,
        onPhaseChange: @escaping (TerminalConnectionPhase) -> Void,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        self.makeConnection = makeConnection
        self.sleep = sleep
        self.onUpdate = onUpdate
        self.onPhaseChange = onPhaseChange
        self.onError = onError
    }

    func start() {
        guard eventsTask == nil else { return }
        isStopped = false
        onPhaseChange(.connecting)
        eventsTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    func stop() {
        isStopped = true
        eventsTask?.cancel()
        eventsTask = nil
        connection?.close()
        connection = nil
    }

    func send(input: String) {
        guard let connection else { return }
        Task {
            do { try await connection.send(input: input) }
            catch { report(error, from: connection) }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard let connection, cols > 0, rows > 0 else { return }
        Task {
            do { try await connection.resize(cols: cols, rows: rows) }
            catch { report(error, from: connection) }
        }
    }

    private func report(
        _ error: Error,
        from failedConnection: any TerminalStreamingConnection
    ) {
        guard !isStopped,
              let connection,
              ObjectIdentifier(connection) == ObjectIdentifier(failedConnection),
              TerminalTransportErrorPolicy.shouldReport(error)
        else { return }
        onError(error.localizedDescription)
    }

    private func runConnectionLoop() async {
        var reconnectAttempt = 0
        defer {
            connection = nil
            eventsTask = nil
        }
        while !Task.isCancelled, !streamState.isExited {
            do {
                let nextConnection = try makeConnection(streamState.cursor)
                connection = nextConnection
                onPhaseChange(.connected)
                for try await event in nextConnection.events() {
                    guard !Task.isCancelled else { return }
                    let previousCursor = streamState.cursor
                    if let update = streamState.apply(event) {
                        if streamState.cursor > previousCursor || event.type == "status" {
                            reconnectAttempt = 0
                        }
                        onUpdate(update)
                    }
                    if streamState.isExited {
                        nextConnection.close()
                        break
                    }
                }
                connection = nil
                guard !Task.isCancelled, !streamState.isExited else { break }
                reconnectAttempt += 1
                guard !finishIfRetryLimitReached(reconnectAttempt, error: nil) else { return }
            } catch {
                connection?.close()
                connection = nil
                guard !Task.isCancelled, !streamState.isExited else { break }
                reconnectAttempt += 1
                guard !finishIfRetryLimitReached(reconnectAttempt, error: error) else { return }
            }
            onPhaseChange(.reconnecting)
            await sleep(TerminalReconnectPolicy.delayMilliseconds(attempt: reconnectAttempt))
        }
        if streamState.isExited { onPhaseChange(.exited) }
    }

    private func finishIfRetryLimitReached(_ attempt: Int, error: Error?) -> Bool {
        guard TerminalReconnectPolicy.shouldStopAutomatically(after: attempt) else { return false }
        onPhaseChange(.failed(
            error?.localizedDescription
                ?? String(localized: "The terminal connection closed unexpectedly.")
        ))
        return true
    }
}

struct TerminalEmulatorView: NSViewRepresentable {
    @AppStorage("appearance.terminalFont") private var terminalFont = "SF Mono"
    let makeConnection: (Int) throws -> any TerminalStreamingConnection
    let onStatus: (String, Int?, String?) -> Void
    let onPhaseChange: (TerminalConnectionPhase) -> Void
    let onFocus: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            makeConnection: makeConnection,
            onStatus: onStatus,
            onPhaseChange: onPhaseChange,
            onFocus: onFocus,
            onError: onError
        )
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.terminalDelegate = context.coordinator
        let focusRecognizer = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.terminalClicked(_:))
        )
        focusRecognizer.delaysPrimaryMouseButtonEvents = false
        focusRecognizer.delegate = context.coordinator
        view.addGestureRecognizer(focusRecognizer)
        view.font = NSFont(name: terminalFont, size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeForegroundColor = .textColor
        view.nativeBackgroundColor = .textBackgroundColor
        context.coordinator.attach(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.onFocus = onFocus
        view.font = NSFont(name: terminalFont, size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate, NSGestureRecognizerDelegate {
        var onFocus: () -> Void
        private weak var terminalView: TerminalView?
        private var recoveryController: TerminalRecoveryController!

        init(
            makeConnection: @escaping (Int) throws -> any TerminalStreamingConnection,
            onStatus: @escaping (String, Int?, String?) -> Void,
            onPhaseChange: @escaping (TerminalConnectionPhase) -> Void,
            onFocus: @escaping () -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onFocus = onFocus
            super.init()
            recoveryController = TerminalRecoveryController(
                makeConnection: makeConnection,
                onUpdate: { [weak self] update in
                    self?.handle(update, onStatus: onStatus)
                },
                onPhaseChange: onPhaseChange,
                onError: onError
            )
        }

        @objc func terminalClicked(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onFocus()
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            true
        }

        func attach(_ view: TerminalView) {
            terminalView = view
            recoveryController.start()
        }

        private func handle(
            _ update: TerminalStreamUpdate,
            onStatus: (String, Int?, String?) -> Void
        ) {
            switch update {
            case let .output(data, reset):
                if reset { terminalView?.getTerminal().resetToInitialState() }
                if !data.isEmpty { terminalView?.feed(text: data) }
            case let .status(status, exitCode, signal):
                onStatus(status, exitCode, signal)
            }
        }

        func disconnect() {
            recoveryController.stop()
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let input = String(decoding: data, as: UTF8.self)
            recoveryController.send(input: input)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            recoveryController.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
