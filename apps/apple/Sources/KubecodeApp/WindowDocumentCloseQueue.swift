import Foundation

enum WindowDocumentCloseQueueState: Equatable {
    case needsDecision(String)
    case readyToClose
    case cancelled
}

struct WindowDocumentCloseQueue {
    private var paths: [String]
    private(set) var state: WindowDocumentCloseQueueState

    init(paths: [String]) {
        var seen: Set<String> = []
        self.paths = paths.filter { seen.insert($0).inserted }
        state = self.paths.first.map(WindowDocumentCloseQueueState.needsDecision)
            ?? .readyToClose
    }

    var currentPath: String? {
        guard case let .needsDecision(path) = state else { return nil }
        return path
    }

    @discardableResult
    mutating func resolveCurrent() -> WindowDocumentCloseQueueState {
        guard case .needsDecision = state, !paths.isEmpty else { return state }
        paths.removeFirst()
        state = paths.first.map(WindowDocumentCloseQueueState.needsDecision)
            ?? .readyToClose
        return state
    }

    mutating func cancel() {
        paths.removeAll()
        state = .cancelled
    }
}
