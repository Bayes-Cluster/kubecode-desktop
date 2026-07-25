import Foundation
import Testing
@testable import KubecodeApp
import KubecodeKit

@Suite(.serialized)
@MainActor
struct TerminalRecoveryIntegrationTests {
    @Test func terminal_socket_shutdown_errors_are_not_user_facing() {
        let notConnected = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOTCONN.rawValue)
        )
        let wrapped = NSError(
            domain: NSURLErrorDomain,
            code: URLError.networkConnectionLost.rawValue,
            userInfo: [NSUnderlyingErrorKey: notConnected]
        )

        #expect(!TerminalTransportErrorPolicy.shouldReport(notConnected))
        #expect(!TerminalTransportErrorPolicy.shouldReport(wrapped))
        #expect(!TerminalTransportErrorPolicy.shouldReport(URLError(.cancelled)))
        #expect(TerminalTransportErrorPolicy.shouldReport(TestFailure.disconnected))
    }

    @Test func reconnect_resumes_from_cursor_and_applies_truncated_snapshot_before_exit() async throws {
        let initial = ScriptedTerminalConnection(
            events: [try event(type: "output", data: "old output", cursor: 5)],
            completion: .failure(TestFailure.disconnected)
        )
        let resumed = ScriptedTerminalConnection(events: [
            try event(type: "output", data: "fresh snapshot", cursor: 19, truncated: true),
            try event(type: "status", status: "exited", exitCode: 0),
        ])
        var connections: [ScriptedTerminalConnection] = [initial, resumed]
        var requestedCursors: [Int] = []
        var updates: [TerminalStreamUpdate] = []
        var phases: [TerminalConnectionPhase] = []
        let controller = TerminalRecoveryController(
            makeConnection: { cursor in
                requestedCursors.append(cursor)
                return connections.removeFirst()
            },
            sleep: { _ in },
            onUpdate: { updates.append($0) },
            onPhaseChange: { phases.append($0) }
        )

        controller.start()
        try await eventually { phases.last == .exited }
        controller.stop()

        #expect(requestedCursors == [0, 5])
        #expect(updates == [
            .output(data: "old output", reset: false),
            .output(data: "fresh snapshot", reset: true),
            .status(status: "exited", exitCode: 0, signal: nil),
        ])
        #expect(phases.contains(.reconnecting))
        #expect(initial.closeCount == 1)
    }

    @Test func connections_that_close_without_progress_exhaust_the_retry_budget() async throws {
        var requestedCursors: [Int] = []
        var phases: [TerminalConnectionPhase] = []
        let controller = TerminalRecoveryController(
            makeConnection: { cursor in
                requestedCursors.append(cursor)
                return ScriptedTerminalConnection(events: [])
            },
            sleep: { _ in },
            onUpdate: { _ in },
            onPhaseChange: { phases.append($0) }
        )

        controller.start()
        try await eventually {
            if case .failed = phases.last { return true }
            return false
        }
        controller.stop()

        #expect(requestedCursors == Array(repeating: 0, count: 5))
        #expect(phases.filter { $0 == .reconnecting }.count == 4)
    }

    private func event(
        type: String,
        data: String? = nil,
        cursor: Int? = nil,
        truncated: Bool? = nil,
        status: String? = nil,
        exitCode: Int? = nil
    ) throws -> TerminalServerEvent {
        var object: [String: Any] = ["type": type]
        if let data { object["data"] = data }
        if let cursor { object["cursor"] = cursor }
        if let truncated { object["truncated"] = truncated }
        if let status { object["status"] = status }
        if let exitCode { object["exit_code"] = exitCode }
        return try JSONDecoder().decode(
            TerminalServerEvent.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func eventually(
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for terminal recovery")
    }
}

private enum TestFailure: Error {
    case disconnected
}

private final class ScriptedTerminalConnection: TerminalStreamingConnection, @unchecked Sendable {
    let scriptedEvents: [TerminalServerEvent]
    let completion: Result<Void, Error>
    private(set) var closeCount = 0

    init(
        events: [TerminalServerEvent],
        completion: Result<Void, Error> = .success(())
    ) {
        scriptedEvents = events
        self.completion = completion
    }

    func events() -> AsyncThrowingStream<TerminalServerEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in scriptedEvents { continuation.yield(event) }
            switch completion {
            case .success: continuation.finish()
            case let .failure(error): continuation.finish(throwing: error)
            }
        }
    }

    func send(input: String) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func close() { closeCount += 1 }
}
