import AppKit

struct AgentMarkdownTypographyKey: Hashable {
    let fontName: String
    let pointSize: Double

    init(fontName: String, pointSize: Double) {
        let typography = WorkspaceTypography(fontName: fontName, pointSize: pointSize)
        self.fontName = typography.fontName
        self.pointSize = typography.pointSize
    }

    init(_ typography: WorkspaceTypography) {
        fontName = typography.fontName
        pointSize = typography.pointSize
    }
}

struct AgentMarkdownRenderInputs: Hashable {
    let contentVersion: Int
    let renderPublicationVersion: Int
    let typography: AgentMarkdownTypographyKey
    let styleRevision: Int
    let tone: AgentMarkdownTone
    let resourceIdentity: String?
    let resourceGeneration: Int
    let attachmentResolutionGeneration: Int
}

struct AgentMarkdownRenderKey: Hashable {
    let inputs: AgentMarkdownRenderInputs
    let effectiveWidth: CGFloat

    init(
        contentVersion: Int,
        renderPublicationVersion: Int,
        typography: AgentMarkdownTypographyKey,
        styleRevision: Int,
        tone: AgentMarkdownTone,
        resourceIdentity: String?,
        resourceGeneration: Int,
        attachmentResolutionGeneration: Int,
        effectiveWidth: CGFloat
    ) {
        inputs = AgentMarkdownRenderInputs(
            contentVersion: contentVersion,
            renderPublicationVersion: renderPublicationVersion,
            typography: typography,
            styleRevision: styleRevision,
            tone: tone,
            resourceIdentity: resourceIdentity,
            resourceGeneration: resourceGeneration,
            attachmentResolutionGeneration: attachmentResolutionGeneration
        )
        self.effectiveWidth = max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
    }

    init(inputs: AgentMarkdownRenderInputs, effectiveWidth: CGFloat) {
        self.inputs = inputs
        self.effectiveWidth = max(effectiveWidth, 1).rounded(.toNearestOrAwayFromZero)
    }

    var contentVersion: Int { inputs.contentVersion }
    var renderPublicationVersion: Int { inputs.renderPublicationVersion }
}

@MainActor
final class AgentMarkdownRenderHeightCommit {
    let renderCommit: AgentMarkdownRenderCommit
    let key: AgentMarkdownRenderKey
    let usedRect: NSRect
    let height: CGFloat

    static func measure(
        renderCommit: AgentMarkdownRenderCommit,
        key: AgentMarkdownRenderKey,
        verticalInset: CGFloat
    ) -> AgentMarkdownRenderHeightCommit {
        precondition(renderCommit.contentVersion == key.contentVersion)
        let measurement = NativeAgentMarkdownMeasurement.measure(
            rendered: renderCommit.attributedValue,
            width: key.effectiveWidth,
            minimumHeight: renderCommit.typography.pointSize + 2,
            verticalInset: verticalInset
        )
        return AgentMarkdownRenderHeightCommit(
            renderCommit: renderCommit,
            key: key,
            usedRect: measurement.usedRect,
            height: measurement.height
        )
    }

    private init(
        renderCommit: AgentMarkdownRenderCommit,
        key: AgentMarkdownRenderKey,
        usedRect: NSRect,
        height: CGFloat
    ) {
        self.renderCommit = renderCommit
        self.key = key
        self.usedRect = usedRect
        self.height = height
    }
}
