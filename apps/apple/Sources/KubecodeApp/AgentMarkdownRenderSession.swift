import Foundation
import KubecodeMarkdown
import Observation

@MainActor
@Observable
final class AgentMarkdownRenderSession {
    typealias RenderScheduler = @MainActor @Sendable (
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never>
    typealias Publisher = @MainActor @Sendable (AgentMarkdownRenderCommit) -> Void

    private struct Style: Equatable {
        let typography: WorkspaceTypography
        let tone: AgentMarkdownTone
        let resourceIdentity: String?
        let styleRevision: Int
        let resourceGeneration: Int
    }

    @ObservationIgnored private let documentBuilder: StreamingMarkdownSession.Builder
    @ObservationIgnored private let documentScheduler: StreamingMarkdownSession.Scheduler
    @ObservationIgnored private let renderScheduler: RenderScheduler
    @ObservationIgnored private let onCommit: Publisher
    @ObservationIgnored private var latestStyle: Style?
    @ObservationIgnored private var latestReceivedGeneration: Int?
    @ObservationIgnored private var latestReceivedContentVersion = 0
    @ObservationIgnored private var latestRenderRequestToken = 0
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var nextAutomaticGeneration = 1
    @ObservationIgnored private var isCancelled = false

    @ObservationIgnored private lazy var streamingSession = StreamingMarkdownSession(
        builder: documentBuilder,
        scheduler: documentScheduler,
        onPublish: { [weak self] snapshot in
            guard let self, let style = self.latestStyle else { return }
            self.receive(
                snapshot,
                typography: style.typography,
                tone: style.tone,
                resourceIdentity: style.resourceIdentity,
                styleRevision: style.styleRevision,
                resourceGeneration: style.resourceGeneration
            )
        }
    )

    private(set) var latestCommit: AgentMarkdownRenderCommit?
    private(set) var preparationCount = 0

    init(
        documentBuilder: @escaping StreamingMarkdownSession.Builder = { source, previous in
            StreamingMarkdownDocument(source: source, previous: previous)
        },
        documentScheduler: @escaping StreamingMarkdownSession.Scheduler = { operation in
            Task.detached(priority: .userInitiated) { await operation() }
        },
        renderScheduler: @escaping RenderScheduler = { operation in
            Task { @MainActor in await operation() }
        },
        onCommit: @escaping Publisher = { _ in }
    ) {
        self.documentBuilder = documentBuilder
        self.documentScheduler = documentScheduler
        self.renderScheduler = renderScheduler
        self.onCommit = onCommit
    }

    var identity: ObjectIdentifier { ObjectIdentifier(self) }
    var latestContentVersion: Int { streamingSession.latestContentVersion }

    @discardableResult
    func submit(
        source: String,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        resourceIdentity: String? = nil,
        styleRevision: Int = 0,
        resourceGeneration: Int = 0
    ) -> StreamingMarkdownSession.SubmissionResult {
        let generation = nextAutomaticGeneration
        nextAutomaticGeneration += 1
        return submit(
            source: source,
            generation: generation,
            typography: typography,
            tone: tone,
            resourceIdentity: resourceIdentity,
            styleRevision: styleRevision,
            resourceGeneration: resourceGeneration
        )
    }

    @discardableResult
    func submit(
        source: String,
        generation: Int,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        resourceIdentity: String? = nil,
        styleRevision: Int = 0,
        resourceGeneration: Int = 0
    ) -> StreamingMarkdownSession.SubmissionResult {
        nextAutomaticGeneration = max(nextAutomaticGeneration, generation + 1)
        let style = Style(
            typography: typography,
            tone: tone,
            resourceIdentity: resourceIdentity,
            styleRevision: styleRevision,
            resourceGeneration: resourceGeneration
        )
        let previousStyle = latestStyle
        latestStyle = style
        let result = streamingSession.submit(source: source, generation: generation)
        if case .unchanged = result,
           previousStyle != style,
           let snapshot = streamingSession.preparedSnapshot
        {
            receive(
                snapshot,
                typography: typography,
                tone: tone,
                resourceIdentity: resourceIdentity,
                styleRevision: styleRevision,
                resourceGeneration: resourceGeneration,
                forceStyleRefresh: true
            )
        }
        return result
    }

    func receive(
        _ snapshot: StreamingMarkdownSession.PreparedSnapshot,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        resourceIdentity: String? = nil,
        styleRevision: Int = 0,
        resourceGeneration: Int = 0,
        forceStyleRefresh: Bool = false
    ) {
        guard !isCancelled,
              forceStyleRefresh
                || latestReceivedGeneration == nil
                || snapshot.generation >= latestReceivedGeneration!
        else { return }

        latestReceivedGeneration = snapshot.generation
        latestReceivedContentVersion = snapshot.contentVersion
        latestRenderRequestToken &+= 1
        let expectedRequestToken = latestRenderRequestToken
        let expectedGeneration = snapshot.generation
        let expectedContentVersion = snapshot.contentVersion
        let previous = latestCommit
        renderTask = renderScheduler { [weak self] in
            guard let self,
                  !self.isCancelled,
                  self.latestRenderRequestToken == expectedRequestToken,
                  self.latestReceivedGeneration == expectedGeneration,
                  self.latestReceivedContentVersion == expectedContentVersion
            else { return }

            let commit = AgentMarkdownRenderCommit.prepare(
                snapshot: snapshot,
                previous: previous,
                typography: typography,
                tone: tone,
                styleRevision: styleRevision,
                resourceIdentity: resourceIdentity,
                resourceGeneration: resourceGeneration
            )
            self.preparationCount += 1

            guard !self.isCancelled,
                  self.latestRenderRequestToken == expectedRequestToken,
                  self.latestReceivedGeneration == expectedGeneration,
                  self.latestReceivedContentVersion == expectedContentVersion
            else { return }
            self.latestCommit = commit
            self.onCommit(commit)
        }
    }

    func cancel() {
        isCancelled = true
        renderTask?.cancel()
        renderTask = nil
        streamingSession.cancel()
    }

    func assertMainActorIsolation() {
        MainActor.assertIsolated()
    }
}
