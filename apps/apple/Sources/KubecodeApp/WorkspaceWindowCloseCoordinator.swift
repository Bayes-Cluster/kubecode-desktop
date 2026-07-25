import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowCloseCoordinator: NSObject, NSWindowDelegate {
    private(set) var model: AppModel
    private weak var window: NSWindow?
    // NSObject forwarding hooks are nonisolated; AppKit queries this delegate on its main thread.
    nonisolated(unsafe) private weak var originalDelegate: (any NSWindowDelegate)?
    private var queue: WindowDocumentCloseQueue?
    private var allowsNextClose = false
    private(set) var presentedAlert: NSAlert?
    private(set) var isReviewing = false

    init(model: AppModel) {
        self.model = model
    }

    func update(model: AppModel) {
        self.model = model
    }

    func attach(to window: NSWindow) {
        guard self.window !== window || window.delegate !== self else { return }
        detach()
        self.window = window
        window.title = ""
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        if window.delegate !== self { originalDelegate = window.delegate }
        window.delegate = self
    }

    func detach() {
        guard let window else { return }
        if window.delegate === self { window.delegate = originalDelegate }
        self.window = nil
        originalDelegate = nil
        presentedAlert = nil
        queue = nil
        isReviewing = false
        allowsNextClose = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowsNextClose {
            allowsNextClose = false
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }
        guard !isReviewing else { return false }
        guard sender.attachedSheet == nil else { return false }

        let dirtyPaths = model.dirtyDocumentPathsForWindowClose()
        guard !dirtyPaths.isEmpty else {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        queue = WindowDocumentCloseQueue(paths: dirtyPaths)
        isReviewing = true
        presentCurrentDecision()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        originalDelegate?.windowWillClose?(notification)
    }

    private func presentCurrentDecision() {
        guard isReviewing,
              let window,
              let path = queue?.currentPath
        else { return }

        guard let document = model.openDocuments.first(where: { $0.path == path }),
              model.isDocumentDirty(document)
        else {
            advanceQueue()
            return
        }

        model.selectDocument(document)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "Save changes to \"%@\"?"),
            fileName
        )
        alert.informativeText = String(localized: "Your changes will be lost if you close this window without saving.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        presentedAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            presentedAlert = nil
            switch response {
            case .alertFirstButtonReturn:
                saveCurrentDocument()
            case .alertSecondButtonReturn:
                advanceQueue()
            default:
                cancelReview()
            }
        }
    }

    private func saveCurrentDocument() {
        guard let path = queue?.currentPath else {
            cancelReview()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var outcome = await model.saveDocumentForWindowClose(path: path)
            while outcome == .busy {
                try? await Task.sleep(for: .milliseconds(100))
                outcome = await model.saveDocumentForWindowClose(path: path)
            }
            switch outcome {
            case .saved:
                advanceQueue()
            case .busy:
                break
            case .failed:
                cancelReview()
            }
        }
    }

    private func advanceQueue() {
        guard var queue else {
            cancelReview()
            return
        }
        let state = queue.resolveCurrent()
        self.queue = queue
        switch state {
        case .needsDecision:
            presentCurrentDecision()
        case .readyToClose:
            finishClose()
        case .cancelled:
            cancelReview()
        }
    }

    private func cancelReview() {
        queue?.cancel()
        queue = nil
        presentedAlert = nil
        isReviewing = false
    }

    private func finishClose() {
        guard let window else {
            cancelReview()
            return
        }
        queue = nil
        isReviewing = false
        allowsNextClose = true
        window.performClose(nil)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector)
            || originalDelegate?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let originalDelegate, originalDelegate.responds(to: aSelector) {
            return originalDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}

private final class WorkspaceWindowProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

struct WorkspaceWindowCloseBridge: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> WorkspaceWindowCloseCoordinator {
        WorkspaceWindowCloseCoordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = WorkspaceWindowProbeView(frame: .zero)
        view.onWindowChange = { window in
            guard let window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(model: model)
        guard let window = nsView.window else { return }
        context.coordinator.attach(to: window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: WorkspaceWindowCloseCoordinator) {
        (nsView as? WorkspaceWindowProbeView)?.onWindowChange = nil
        coordinator.detach()
    }
}
