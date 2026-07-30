import Foundation
import KubecodeMarkdown

@MainActor
final class StreamingMarkdownSession {
    struct PreparedSnapshot: Equatable, Sendable {
        let source: String
        let generation: Int
        let contentVersion: Int
        let document: StreamingMarkdownDocument
    }

    enum SubmissionResult: Equatable, Sendable {
        case rejected
        case accepted(contentVersion: Int)
        case unchanged(contentVersion: Int)
    }

    typealias Builder = @Sendable (
        _ source: String,
        _ previous: StreamingMarkdownDocument?
    ) async -> StreamingMarkdownDocument
    typealias Scheduler = @MainActor @Sendable (
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>
    typealias Publisher = @MainActor @Sendable (PreparedSnapshot) -> Void

    private struct BuildRequest: Sendable {
        let jobID: UInt64
        let source: String
        var generation: Int
        let contentVersion: Int
    }

    private let builder: Builder
    private let scheduler: Scheduler
    private let onPublish: Publisher
    private var nextJobID: UInt64 = 1
    private var activeRequest: BuildRequest?
    private var pendingRequest: BuildRequest?
    private var activeTask: Task<Void, Never>?
    private var latestSubmittedSource: String?
    private var lastBuiltDocument: StreamingMarkdownDocument?

    private(set) var latestSubmittedGeneration: Int?
    private(set) var latestContentVersion = 0
    private(set) var preparedSnapshot: PreparedSnapshot?
    private(set) var isCancelled = false

    init(
        builder: @escaping Builder = { source, previous in
            StreamingMarkdownDocument(source: source, previous: previous)
        },
        scheduler: @escaping Scheduler = { operation in
            Task.detached(priority: .userInitiated) { await operation() }
        },
        onPublish: @escaping Publisher = { _ in }
    ) {
        self.builder = builder
        self.scheduler = scheduler
        self.onPublish = onPublish
    }

    deinit {
        activeTask?.cancel()
    }

    @discardableResult
    func submit(source: String, generation: Int) -> SubmissionResult {
        guard !isCancelled else { return .rejected }
        if let latestSubmittedGeneration, generation <= latestSubmittedGeneration {
            return .rejected
        }

        latestSubmittedGeneration = generation
        if source == latestSubmittedSource {
            retagUnchangedSource(generation: generation)
            return .unchanged(contentVersion: latestContentVersion)
        }

        latestSubmittedSource = source
        latestContentVersion += 1
        let request = BuildRequest(
            jobID: nextJobID,
            source: source,
            generation: generation,
            contentVersion: latestContentVersion
        )
        nextJobID += 1

        if activeRequest == nil {
            start(request)
        } else {
            pendingRequest = request
        }
        return .accepted(contentVersion: request.contentVersion)
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        pendingRequest = nil
        activeRequest = nil
        let task = activeTask
        activeTask = nil
        task?.cancel()
    }

    var activeBuildCount: Int { activeRequest == nil ? 0 : 1 }
    var pendingSnapshotCount: Int { pendingRequest == nil ? 0 : 1 }
    var scheduledWorkCount: Int { activeBuildCount + pendingSnapshotCount }

    private func retagUnchangedSource(generation: Int) {
        if pendingRequest?.source == latestSubmittedSource {
            pendingRequest?.generation = generation
            return
        }
        if activeRequest?.source == latestSubmittedSource {
            activeRequest?.generation = generation
            return
        }
        guard let preparedSnapshot,
              preparedSnapshot.source == latestSubmittedSource,
              preparedSnapshot.contentVersion == latestContentVersion
        else { return }
        self.preparedSnapshot = .init(
            source: preparedSnapshot.source,
            generation: generation,
            contentVersion: preparedSnapshot.contentVersion,
            document: preparedSnapshot.document
        )
    }

    private func start(_ request: BuildRequest) {
        activeRequest = request
        let builder = builder
        let previous = lastBuiltDocument ?? preparedSnapshot?.document
        activeTask = scheduler { [weak self] in
            let document = await builder(request.source, previous)
            await self?.complete(
                jobID: request.jobID,
                builtSource: request.source,
                builtContentVersion: request.contentVersion,
                document: document
            )
        }
    }

    private func complete(
        jobID: UInt64,
        builtSource: String,
        builtContentVersion: Int,
        document: StreamingMarkdownDocument
    ) {
        guard let completedRequest = activeRequest,
              completedRequest.jobID == jobID
        else { return }

        activeRequest = nil
        activeTask = nil
        if document.source == builtSource {
            lastBuiltDocument = document
        }

        if !isCancelled,
           completedRequest.source == builtSource,
           completedRequest.contentVersion == builtContentVersion,
           completedRequest.generation == latestSubmittedGeneration,
           completedRequest.contentVersion == latestContentVersion,
           completedRequest.source == latestSubmittedSource,
           document.source == completedRequest.source
        {
            publish(.init(
                source: completedRequest.source,
                generation: completedRequest.generation,
                contentVersion: completedRequest.contentVersion,
                document: document
            ))
        }

        guard !isCancelled, let pendingRequest else { return }
        self.pendingRequest = nil
        start(pendingRequest)
    }

    private func publish(_ snapshot: PreparedSnapshot) {
        preparedSnapshot = snapshot
        onPublish(snapshot)
    }
}
