import AppKit
import KubecodeMarkdown
import Observation

enum AgentMarkdownRenderSegment: String, Hashable, Sendable {
    case standalone
    case userMessage
    case agentResponse
    case thinking
    case activityUpdate
    case runOutput
}

struct AgentMarkdownRenderScope: Hashable, Sendable {
    let projectIdentity: String?
    let sessionID: String?
}

struct AgentMarkdownRenderIdentity: Hashable, Sendable {
    let scope: AgentMarkdownRenderScope
    let rowID: String
    let semanticItemID: String
    let segment: AgentMarkdownRenderSegment

    init(
        scope: AgentMarkdownRenderScope,
        rowID: String,
        semanticItemID: String? = nil,
        segment: AgentMarkdownRenderSegment
    ) {
        self.scope = scope
        self.rowID = rowID
        self.semanticItemID = semanticItemID ?? rowID
        self.segment = segment
    }

    static func legacy(rowID: String) -> Self {
        Self(
            scope: .init(projectIdentity: nil, sessionID: nil),
            rowID: rowID,
            segment: .standalone
        )
    }
}

@MainActor
@Observable
final class AgentMarkdownRenderStore {
    typealias AttachmentResolver = @Sendable (
        _ load: AgentMarkdownImageLoad,
        _ resourceContext: MarkdownProjectResourceContext?
    ) async -> Data?

    private struct SemanticRequest: Equatable {
        let source: String
        let typography: WorkspaceTypography
        let tone: AgentMarkdownTone
        let styleRevision: Int
        let resourceIdentity: String?
        let resourceGeneration: Int
    }

    private final class Row {
        var session: AgentMarkdownRenderSession!
        var commit: AgentMarkdownRenderCommit?
        var inputs: AgentMarkdownRenderInputs?
        var heights: [AgentMarkdownRenderKey: AgentMarkdownRenderHeightCommit] = [:]
        var heightOrder: [AgentMarkdownRenderKey] = []
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
        var semanticRequest: SemanticRequest?
        var attachmentRequestEpoch = 0
    }

    @ObservationIgnored private let documentBuilder: StreamingMarkdownSession.Builder
    @ObservationIgnored private let documentScheduler: StreamingMarkdownSession.Scheduler
    @ObservationIgnored private let renderScheduler: AgentMarkdownRenderSession.RenderScheduler
    @ObservationIgnored private let attachmentResolver: AttachmentResolver
    @ObservationIgnored private let capacity: Int
    @ObservationIgnored private let heightCapacityPerRow: Int
    @ObservationIgnored private var rows: [AgentMarkdownRenderIdentity: Row] = [:]
    @ObservationIgnored private var rowOrder: [AgentMarkdownRenderIdentity] = []
    @ObservationIgnored private var resourceGenerations: [String: Int] = [:]
    @ObservationIgnored private var activeScope: AgentMarkdownRenderScope?
    @ObservationIgnored private var measurementCount = 0

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
        },
        capacity: Int = 512,
        heightCapacityPerRow: Int = 8
    ) {
        self.documentBuilder = documentBuilder
        self.documentScheduler = documentScheduler
        self.renderScheduler = renderScheduler
        self.attachmentResolver = attachmentResolver
        self.capacity = max(1, capacity)
        self.heightCapacityPerRow = max(1, heightCapacityPerRow)
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
        submit(
            identity: .legacy(rowID: rowID),
            source: source,
            typography: typography,
            tone: tone,
            styleIdentity: styleIdentity,
            resourceContext: resourceContext
        )
    }

    @discardableResult
    func submit(
        identity: AgentMarkdownRenderIdentity,
        source: String,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        styleIdentity: Int = 0,
        resourceContext: MarkdownProjectResourceContext? = nil
    ) -> StreamingMarkdownSession.SubmissionResult {
        let row = row(for: identity)
        activateStyle(row, identity: styleIdentity)
        activateResourceContext(row, context: resourceContext)
        activateSemanticRequest(
            row,
            source: source,
            typography: typography,
            tone: tone
        )
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
        latestRenderCommit(identity: .legacy(rowID: rowID))
    }

    func latestRenderCommit(
        identity: AgentMarkdownRenderIdentity
    ) -> AgentMarkdownRenderCommit? {
        _ = changeToken
        guard let row = rows[identity] else { return nil }
        touch(identity)
        return row.commit
    }

    func latestRenderInputs(rowID: String) -> AgentMarkdownRenderInputs? {
        latestRenderInputs(identity: .legacy(rowID: rowID))
    }

    func latestRenderInputs(
        identity: AgentMarkdownRenderIdentity
    ) -> AgentMarkdownRenderInputs? {
        guard let row = rows[identity] else { return nil }
        touch(identity)
        return row.inputs
    }

    func heightCommit(
        rowID: String,
        width: CGFloat,
        verticalInset: CGFloat
    ) -> AgentMarkdownRenderHeightCommit? {
        heightCommit(
            identity: .legacy(rowID: rowID),
            width: width,
            verticalInset: verticalInset
        )
    }

    func heightCommit(
        identity: AgentMarkdownRenderIdentity,
        width: CGFloat,
        verticalInset: CGFloat
    ) -> AgentMarkdownRenderHeightCommit? {
        guard let row = rows[identity],
              let renderCommit = row.commit,
              let inputs = row.inputs
        else { return nil }
        touch(identity)
        let key = AgentMarkdownRenderKey(inputs: inputs, effectiveWidth: width)
        if let cached = row.heights[key], cached.renderCommit === renderCommit {
            touchHeight(key, in: row)
            return cached
        }
        let measured = AgentMarkdownRenderHeightCommit.measure(
            renderCommit: renderCommit,
            key: key,
            verticalInset: verticalInset
        )
        guard row.commit === renderCommit, row.inputs == inputs else { return nil }
        measurementCount &+= 1
        row.heights[key] = measured
        touchHeight(key, in: row)
        while row.heightOrder.count > heightCapacityPerRow {
            row.heights.removeValue(forKey: row.heightOrder.removeFirst())
        }
        return measured
    }

    @discardableResult
    func settleAttachments(
        rowID: String,
        expectedRenderPublicationVersion: Int,
        images: [String: NSImage],
        expectedAttachmentRequestEpoch: Int
    ) -> Bool {
        settleAttachments(
            identity: .legacy(rowID: rowID),
            expectedRenderPublicationVersion: expectedRenderPublicationVersion,
            images: images,
            expectedAttachmentRequestEpoch: expectedAttachmentRequestEpoch
        )
    }

    @discardableResult
    func settleAttachments(
        identity: AgentMarkdownRenderIdentity,
        expectedRenderPublicationVersion: Int,
        images: [String: NSImage],
        expectedAttachmentRequestEpoch: Int
    ) -> Bool {
        guard !images.isEmpty,
              let row = rows[identity],
              let base = row.commit,
              let inputs = row.inputs,
              inputs.renderPublicationVersion == expectedRenderPublicationVersion,
              row.attachmentResolutionGeneration == inputs.attachmentResolutionGeneration,
              expectedAttachmentRequestEpoch == row.attachmentRequestEpoch
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
        row.heightOrder.removeAll(keepingCapacity: true)
        row.settlingPublicationVersion = nil
        changeToken &+= 1
        return true
    }

    @discardableResult
    func invalidateResourceContext(identity: String, projectPath: String? = nil) -> Int {
        let normalizedPath = projectPath.flatMap(
            MarkdownResourcePolicy.projectRelativeImagePath
        )
        guard projectPath == nil || normalizedPath != nil else { return 0 }
        let affectedRows = rows.values.filter { row in
            guard row.resourceIdentity == identity else { return false }
            let projectLoads = row.commit?.document.imageLoads.filter {
                $0.projectPath != nil
            } ?? []
            return projectLoads.contains { load in
                guard let normalizedPath else { return true }
                return load.projectPath == normalizedPath
            }
        }
        guard !affectedRows.isEmpty else { return 0 }
        resourceGenerations[identity, default: 0] &+= 1
        let generation = resourceGenerations[identity]!
        for row in affectedRows {
            row.resourceGeneration = generation
            if let source = row.latestSource,
               let typography = row.latestTypography,
               let tone = row.latestTone
            {
                activateSemanticRequest(
                    row,
                    source: source,
                    typography: typography,
                    tone: tone
                )
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
        return affectedRows.count
    }

    func removeAll() {
        removeAllRows()
        resourceGenerations.removeAll(keepingCapacity: false)
        activeScope = nil
    }

    func reconcile(
        scope: AgentMarkdownRenderScope,
        retainingRowIDs: Set<String>
    ) {
        if activeScope != scope {
            removeAllRows()
            resourceGenerations.removeAll(keepingCapacity: false)
            activeScope = scope
        }
        let removed = rows.keys.filter {
            $0.scope == scope && !retainingRowIDs.contains($0.rowID)
        }
        for identity in removed { remove(identity: identity) }
    }

    func remove(identity: AgentMarkdownRenderIdentity) {
        guard let row = rows.removeValue(forKey: identity) else { return }
        cancel(row)
        rowOrder.removeAll { $0 == identity }
        changeToken &+= 1
    }

    func remove(scope: AgentMarkdownRenderScope) {
        let removed = rows.keys.filter { $0.scope == scope }
        for identity in removed { remove(identity: identity) }
        if activeScope == scope { activeScope = nil }
    }

    func assertMainActorIsolation() {
        MainActor.assertIsolated()
    }

#if DEBUG
    var testingRowIDs: Set<String> { Set(rows.keys.map(\.rowID)) }
    var testingIdentities: Set<AgentMarkdownRenderIdentity> { Set(rows.keys) }
    var testingMeasurementCount: Int { measurementCount }

    func testingSession(
        identity: AgentMarkdownRenderIdentity
    ) -> AgentMarkdownRenderSession? {
        rows[identity]?.session
    }

    func testingHeightKeys(
        identity: AgentMarkdownRenderIdentity
    ) -> [AgentMarkdownRenderKey] {
        rows[identity]?.heightOrder ?? []
    }
#endif

    private func row(for identity: AgentMarkdownRenderIdentity) -> Row {
        activate(scope: identity.scope)
        if let row = rows[identity] {
            touch(identity)
            return row
        }
        while rows.count >= capacity, let oldest = rowOrder.first {
            remove(identity: oldest)
        }
        let row = Row()
        row.session = AgentMarkdownRenderSession(
            documentBuilder: documentBuilder,
            documentScheduler: documentScheduler,
            renderScheduler: renderScheduler,
            onCommit: { [weak self] commit in
                self?.accept(commit, identity: identity)
            }
        )
        rows[identity] = row
        touch(identity)
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

    private func accept(
        _ commit: AgentMarkdownRenderCommit,
        identity: AgentMarkdownRenderIdentity
    ) {
        guard let row = rows[identity],
              row.session.latestCommit === commit,
              row.semanticRequest == SemanticRequest(
                source: commit.source,
                typography: commit.typography,
                tone: commit.tone,
                styleRevision: commit.styleRevision,
                resourceIdentity: commit.resourceIdentity,
                resourceGeneration: commit.resourceGeneration
              )
        else { return }
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
        row.heightOrder.removeAll(keepingCapacity: true)
        changeToken &+= 1
        resolveAttachmentsIfNeeded(identity: identity, row: row, commit: acceptedCommit)
    }

    private func resolveAttachmentsIfNeeded(
        identity: AgentMarkdownRenderIdentity,
        row: Row,
        commit: AgentMarkdownRenderCommit
    ) {
        let loads = commit.document.imageLoads
        guard !loads.isEmpty, row.settlingPublicationVersion == nil else { return }
        let expectedPublication = row.renderPublicationVersion
        let expectedResourceIdentity = row.resourceIdentity
        let expectedResourceGeneration = row.resourceGeneration
        let expectedAttachmentRequestEpoch = row.attachmentRequestEpoch
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
                  let current = self.rows[identity],
                  current.commit === commit,
                  current.renderPublicationVersion == expectedPublication,
                  current.resourceIdentity == expectedResourceIdentity,
                  current.resourceGeneration == expectedResourceGeneration,
                  current.attachmentRequestEpoch == expectedAttachmentRequestEpoch
            else { return }
            var images: [String: NSImage] = [:]
            for (source, data) in loaded {
                if let data, let image = MarkdownRemoteImageDecoder.image(from: data) {
                    images[source] = image
                }
            }
            if !self.settleAttachments(
                identity: identity,
                expectedRenderPublicationVersion: expectedPublication,
                images: images,
                expectedAttachmentRequestEpoch: expectedAttachmentRequestEpoch
            ) {
                current.settlingPublicationVersion = nil
            }
            current.attachmentTask = nil
        }
    }

    private func activate(scope: AgentMarkdownRenderScope) {
        guard activeScope != scope else { return }
        removeAllRows()
        resourceGenerations.removeAll(keepingCapacity: false)
        activeScope = scope
    }

    private func touch(_ identity: AgentMarkdownRenderIdentity) {
        rowOrder.removeAll { $0 == identity }
        rowOrder.append(identity)
    }

    private func touchHeight(_ key: AgentMarkdownRenderKey, in row: Row) {
        row.heightOrder.removeAll { $0 == key }
        row.heightOrder.append(key)
    }

    private func cancel(_ row: Row) {
        row.attachmentRequestEpoch &+= 1
        row.attachmentTask?.cancel()
        row.attachmentTask = nil
        row.session.cancel()
    }

    private func removeAllRows() {
        guard !rows.isEmpty else {
            rowOrder.removeAll(keepingCapacity: false)
            return
        }
        for row in rows.values { cancel(row) }
        rows.removeAll(keepingCapacity: false)
        rowOrder.removeAll(keepingCapacity: false)
        changeToken &+= 1
    }

    private func activateSemanticRequest(
        _ row: Row,
        source: String,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone
    ) {
        let request = SemanticRequest(
            source: source,
            typography: typography,
            tone: tone,
            styleRevision: row.styleRevision,
            resourceIdentity: row.resourceIdentity,
            resourceGeneration: row.resourceGeneration
        )
        guard row.semanticRequest != request else { return }
        row.semanticRequest = request
        row.attachmentRequestEpoch &+= 1
        row.attachmentTask?.cancel()
        row.attachmentTask = nil
        row.settlingPublicationVersion = nil
    }
}
