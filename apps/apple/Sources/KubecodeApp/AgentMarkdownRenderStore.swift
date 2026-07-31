import AppKit
import KubecodeMarkdown
import Observation

@MainActor
@Observable
final class AgentMarkdownRenderStore {
    typealias AttachmentResolver = @Sendable (
        _ load: AgentMarkdownImageLoad,
        _ resourceContext: MarkdownProjectResourceContext?
    ) async -> Data?

    private final class Row {
        var session: AgentMarkdownRenderSession!
        var commit: AgentMarkdownRenderCommit?
        var inputs: AgentMarkdownRenderInputs?
        var heights: [AgentMarkdownRenderKey: AgentMarkdownRenderHeightCommit] = [:]
        var styleIdentity: Int?
        var styleRevision = 0
        var resourceIdentity: String?
        var resourceGeneration = 0
        var attachmentResolutionGeneration = 0
        var renderPublicationVersion = 0
        var resourceContext: MarkdownProjectResourceContext?
        var latestSource: String?
        var latestTypography: WorkspaceTypography?
        var latestTone: AgentMarkdownTone?
        var attachmentTask: Task<Void, Never>?
        var settlingPublicationVersion: Int?
    }

    @ObservationIgnored private let documentBuilder: StreamingMarkdownSession.Builder
    @ObservationIgnored private let documentScheduler: StreamingMarkdownSession.Scheduler
    @ObservationIgnored private let renderScheduler: AgentMarkdownRenderSession.RenderScheduler
    @ObservationIgnored private let attachmentResolver: AttachmentResolver
    @ObservationIgnored private var rows: [String: Row] = [:]
    @ObservationIgnored private var resourceGenerations: [String: Int] = [:]

    private(set) var changeToken = 0

    init(
        documentBuilder: @escaping StreamingMarkdownSession.Builder = { source, previous in
            StreamingMarkdownDocument(source: source, previous: previous)
        },
        documentScheduler: @escaping StreamingMarkdownSession.Scheduler = { operation in
            Task.detached(priority: .userInitiated) { await operation() }
        },
        renderScheduler: @escaping AgentMarkdownRenderSession.RenderScheduler = { operation in
            Task { @MainActor in await operation() }
        },
        attachmentResolver: @escaping AttachmentResolver = { load, resourceContext in
            if let url = load.remoteURL {
                return await MarkdownRemoteImageLoader.shared.data(for: url)
            }
            if let path = load.projectPath, let resourceContext {
                return await resourceContext.data(for: path)
            }
            return nil
        }
    ) {
        self.documentBuilder = documentBuilder
        self.documentScheduler = documentScheduler
        self.renderScheduler = renderScheduler
        self.attachmentResolver = attachmentResolver
    }

    @discardableResult
    func submit(
        rowID: String,
        source: String,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        styleIdentity: Int = 0,
        resourceContext: MarkdownProjectResourceContext? = nil
    ) -> StreamingMarkdownSession.SubmissionResult {
        let row = row(for: rowID)
        activateStyle(row, identity: styleIdentity)
        activateResourceContext(row, context: resourceContext)
        row.latestSource = source
        row.latestTypography = typography
        row.latestTone = tone
        return row.session.submit(
            source: source,
            typography: typography,
            tone: tone,
            resourceIdentity: row.resourceIdentity,
            styleRevision: row.styleRevision,
            resourceGeneration: row.resourceGeneration
        )
    }

    func latestRenderCommit(rowID: String) -> AgentMarkdownRenderCommit? {
        _ = changeToken
        return rows[rowID]?.commit
    }

    func latestRenderInputs(rowID: String) -> AgentMarkdownRenderInputs? {
        rows[rowID]?.inputs
    }

    func heightCommit(
        rowID: String,
        width: CGFloat,
        verticalInset: CGFloat
    ) -> AgentMarkdownRenderHeightCommit? {
        guard let row = rows[rowID],
              let renderCommit = row.commit,
              let inputs = row.inputs
        else { return nil }
        let key = AgentMarkdownRenderKey(inputs: inputs, effectiveWidth: width)
        if let cached = row.heights[key], cached.renderCommit === renderCommit {
            return cached
        }
        let measured = AgentMarkdownRenderHeightCommit.measure(
            renderCommit: renderCommit,
            key: key,
            verticalInset: verticalInset
        )
        guard row.commit === renderCommit, row.inputs == inputs else { return nil }
        row.heights[key] = measured
        return measured
    }

    @discardableResult
    func settleAttachments(
        rowID: String,
        expectedRenderPublicationVersion: Int,
        images: [String: NSImage]
    ) -> Bool {
        guard !images.isEmpty,
              let row = rows[rowID],
              let base = row.commit,
              let inputs = row.inputs,
              inputs.renderPublicationVersion == expectedRenderPublicationVersion,
              row.attachmentResolutionGeneration == inputs.attachmentResolutionGeneration
        else { return false }

        row.attachmentResolutionGeneration += 1
        row.renderPublicationVersion += 1
        let settled = AgentMarkdownRenderCommit.prepare(
            snapshot: base.snapshot,
            previous: base,
            typography: base.typography,
            tone: base.tone,
            images: images,
            styleRevision: base.styleRevision,
            resourceIdentity: base.resourceIdentity,
            resourceGeneration: base.resourceGeneration
        )
        row.commit = settled
        row.inputs = AgentMarkdownRenderInputs(
            contentVersion: settled.contentVersion,
            renderPublicationVersion: row.renderPublicationVersion,
            typography: AgentMarkdownTypographyKey(settled.typography),
            styleRevision: settled.styleRevision,
            tone: settled.tone,
            resourceIdentity: settled.resourceIdentity,
            resourceGeneration: settled.resourceGeneration,
            attachmentResolutionGeneration: row.attachmentResolutionGeneration
        )
        row.heights.removeAll(keepingCapacity: true)
        row.settlingPublicationVersion = nil
        changeToken &+= 1
        return true
    }

    func invalidateResourceContext(identity: String) {
        resourceGenerations[identity, default: 0] &+= 1
        for row in rows.values where row.resourceIdentity == identity {
            row.resourceGeneration = resourceGenerations[identity]!
            if let source = row.latestSource,
               let typography = row.latestTypography,
               let tone = row.latestTone
            {
                _ = row.session.submit(
                    source: source,
                    typography: typography,
                    tone: tone,
                    resourceIdentity: identity,
                    styleRevision: row.styleRevision,
                    resourceGeneration: row.resourceGeneration
                )
            }
        }
    }

    func removeAll() {
        for row in rows.values {
            row.attachmentTask?.cancel()
            row.session.cancel()
        }
        rows.removeAll(keepingCapacity: false)
        resourceGenerations.removeAll(keepingCapacity: false)
        changeToken &+= 1
    }

    func assertMainActorIsolation() {
        MainActor.assertIsolated()
    }

    private func row(for rowID: String) -> Row {
        if let row = rows[rowID] { return row }
        let row = Row()
        row.session = AgentMarkdownRenderSession(
            documentBuilder: documentBuilder,
            documentScheduler: documentScheduler,
            renderScheduler: renderScheduler,
            onCommit: { [weak self] commit in
                self?.accept(commit, rowID: rowID)
            }
        )
        rows[rowID] = row
        return row
    }

    private func activateStyle(_ row: Row, identity: Int) {
        guard row.styleIdentity != identity else { return }
        row.styleIdentity = identity
        row.styleRevision &+= 1
    }

    private func activateResourceContext(
        _ row: Row,
        context: MarkdownProjectResourceContext?
    ) {
        let identity = context?.identity
        if row.resourceIdentity != identity {
            row.resourceIdentity = identity
            if let identity {
                if resourceGenerations[identity] == nil {
                    resourceGenerations[identity] = 1
                }
                row.resourceGeneration = resourceGenerations[identity]!
            } else {
                row.resourceGeneration = 0
            }
        }
        row.resourceContext = context
    }

    private func accept(_ commit: AgentMarkdownRenderCommit, rowID: String) {
        guard let row = rows[rowID], row.session.latestCommit === commit else { return }
        let acceptedCommit = row.commit.map {
            commit.carryingStablePrefix(from: $0)
        } ?? commit
        row.attachmentTask?.cancel()
        row.attachmentTask = nil
        row.settlingPublicationVersion = nil
        row.attachmentResolutionGeneration = 0
        row.renderPublicationVersion &+= 1
        row.commit = acceptedCommit
        row.inputs = AgentMarkdownRenderInputs(
            contentVersion: acceptedCommit.contentVersion,
            renderPublicationVersion: row.renderPublicationVersion,
            typography: AgentMarkdownTypographyKey(acceptedCommit.typography),
            styleRevision: acceptedCommit.styleRevision,
            tone: acceptedCommit.tone,
            resourceIdentity: acceptedCommit.resourceIdentity,
            resourceGeneration: acceptedCommit.resourceGeneration,
            attachmentResolutionGeneration: 0
        )
        row.heights.removeAll(keepingCapacity: true)
        changeToken &+= 1
        resolveAttachmentsIfNeeded(rowID: rowID, row: row, commit: acceptedCommit)
    }

    private func resolveAttachmentsIfNeeded(
        rowID: String,
        row: Row,
        commit: AgentMarkdownRenderCommit
    ) {
        let loads = commit.document.imageLoads
        guard !loads.isEmpty, row.settlingPublicationVersion == nil else { return }
        let expectedPublication = row.renderPublicationVersion
        let expectedResourceIdentity = row.resourceIdentity
        let expectedResourceGeneration = row.resourceGeneration
        let resourceContext = row.resourceContext
        row.settlingPublicationVersion = expectedPublication
        row.attachmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = await withTaskGroup(
                of: (String, Data?).self,
                returning: [(String, Data?)].self
            ) { group in
                for load in loads {
                    group.addTask { [attachmentResolver] in
                        (load.source, await attachmentResolver(load, resourceContext))
                    }
                }
                var results: [(String, Data?)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard !Task.isCancelled,
                  let current = self.rows[rowID],
                  current.commit === commit,
                  current.renderPublicationVersion == expectedPublication,
                  current.resourceIdentity == expectedResourceIdentity,
                  current.resourceGeneration == expectedResourceGeneration
            else { return }
            var images: [String: NSImage] = [:]
            for (source, data) in loaded {
                if let data, let image = MarkdownRemoteImageDecoder.image(from: data) {
                    images[source] = image
                }
            }
            if !self.settleAttachments(
                rowID: rowID,
                expectedRenderPublicationVersion: expectedPublication,
                images: images
            ) {
                current.settlingPublicationVersion = nil
            }
            current.attachmentTask = nil
        }
    }
}
