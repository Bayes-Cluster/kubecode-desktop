import SwiftUI
#if os(macOS)
import AppKit
#endif

enum NativeListSelection {
    static func reconciled(current: String?, identifiers: [String]) -> String? {
        guard !identifiers.isEmpty else { return nil }
        if let current, identifiers.contains(current) { return current }
        return identifiers[0]
    }

    static func moved(current: String?, offset: Int, identifiers: [String]) -> String? {
        guard !identifiers.isEmpty else { return nil }
        guard let current, let index = identifiers.firstIndex(of: current) else {
            return identifiers[0]
        }
        let destination = min(max(index + offset, identifiers.startIndex), identifiers.index(before: identifiers.endIndex))
        return identifiers[destination]
    }
}

#if os(macOS)
struct NativeListCommandMonitor: NSViewRepresentable {
    let onMove: (Int) -> Bool
    let onOpen: () -> Bool
    let onEscape: (() -> Void)?

    init(
        onMove: @escaping (Int) -> Bool,
        onOpen: @escaping () -> Bool,
        onEscape: (() -> Void)? = nil
    ) {
        self.onMove = onMove
        self.onOpen = onOpen
        self.onEscape = onEscape
    }

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.onMove = onMove
        view.onOpen = onOpen
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: KeyMonitorView, context: Context) {
        view.onMove = onMove
        view.onOpen = onOpen
        view.onEscape = onEscape
    }

    static func dismantleNSView(_ view: KeyMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class KeyMonitorView: NSView {
        var onMove: ((Int) -> Bool)?
        var onOpen: (() -> Bool)?
        var onEscape: (() -> Void)?
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.consume(event) ?? event
            }
        }

        func consume(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let commandModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard commandModifiers.isEmpty else { return event }
            switch event.keyCode {
            case 53:
                guard let onEscape else { return event }
                onEscape()
                return nil
            case 125:
                return onMove?(1) == true ? nil : event
            case 126:
                return onMove?(-1) == true ? nil : event
            case 36, 76:
                return onOpen?() == true ? nil : event
            default:
                return event
            }
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }
}
#endif
