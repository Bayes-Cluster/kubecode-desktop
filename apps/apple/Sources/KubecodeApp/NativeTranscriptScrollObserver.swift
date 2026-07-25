#if os(macOS)
import AppKit
import SwiftUI

struct NativeTranscriptScrollObserver: NSViewRepresentable {
    let onNearBottomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNearBottomChanged: onNearBottomChanged)
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        context.coordinator.onNearBottomChanged = onNearBottomChanged
        view.coordinator = context.coordinator
        context.coordinator.scheduleAttachment(from: view)
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ObserverView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.scheduleAttachment(from: self)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onNearBottomChanged: (Bool) -> Void
        private weak var scrollView: NSScrollView?
        private var lastReportedValue: Bool?
        private var isLiveScrolling = false

        init(onNearBottomChanged: @escaping (Bool) -> Void) {
            self.onNearBottomChanged = onNearBottomChanged
        }

        func scheduleAttachment(from view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.attach(to: view.enclosingScrollView)
            }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
            lastReportedValue = nil
            isLiveScrolling = false
        }

        private func attach(to nextScrollView: NSScrollView?) {
            guard scrollView !== nextScrollView else { return }
            detach()
            guard let nextScrollView else { return }
            scrollView = nextScrollView
            nextScrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: nextScrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(liveScrollWillStart),
                name: NSScrollView.willStartLiveScrollNotification,
                object: nextScrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(liveScrollDidEnd),
                name: NSScrollView.didEndLiveScrollNotification,
                object: nextScrollView
            )
            reportPosition()
        }

        @objc private func clipViewBoundsDidChange() {
            guard isLiveScrolling || Self.currentEventIsUserNavigation else { return }
            reportPosition()
        }

        @objc private func liveScrollWillStart() {
            isLiveScrolling = true
        }

        @objc private func liveScrollDidEnd() {
            reportPosition()
            isLiveScrolling = false
        }

        func reportUserNavigation() {
            reportPosition()
        }

        private func reportPosition() {
            guard let scrollView else { return }
            let isNearBottom = Self.isNearBottom(scrollView)
            guard isNearBottom != lastReportedValue else { return }
            lastReportedValue = isNearBottom
            onNearBottomChanged(isNearBottom)
        }

        private static var currentEventIsUserNavigation: Bool {
            guard let type = NSApp.currentEvent?.type else { return false }
            return type == .scrollWheel || type == .leftMouseDragged || type == .keyDown
        }

        private static func isNearBottom(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let visible = scrollView.documentVisibleRect
            let documentBounds = documentView.bounds
            let distance: CGFloat
            if documentView.isFlipped {
                distance = documentBounds.maxY - visible.maxY
            } else {
                distance = visible.minY - documentBounds.minY
            }
            // SwiftUI keeps a small native trailing inset even after scrollTo(..., .bottom).
            return distance <= 80
        }
    }
}
#endif
