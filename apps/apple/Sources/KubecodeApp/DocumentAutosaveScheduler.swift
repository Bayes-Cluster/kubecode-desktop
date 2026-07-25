import Foundation

@MainActor
final class DocumentAutosaveScheduler {
    static let defaultDelay: Duration = .seconds(1)

    private let delay: Duration
    private var tasks: [String: Task<Void, Never>] = [:]

    init(delay: Duration = defaultDelay) {
        self.delay = delay
    }

    func schedule(key: String, action: @escaping @MainActor () -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
            self?.tasks.removeValue(forKey: key)
        }
    }

    func cancel(key: String) {
        tasks.removeValue(forKey: key)?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
    }
}
