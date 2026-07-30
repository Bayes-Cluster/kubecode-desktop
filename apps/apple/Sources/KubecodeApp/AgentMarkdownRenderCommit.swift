import AppKit
import KubecodeMarkdown

@MainActor
final class AgentMarkdownRenderCommit {
    struct Block {
        let id: String
        let sourceRange: MarkdownSourceRange?
        let attributedValue: NSAttributedString
        let attributedRange: NSRange
    }

    let source: String
    let generation: Int
    let contentVersion: Int
    let snapshot: StreamingMarkdownSession.PreparedSnapshot
    let typography: WorkspaceTypography
    let tone: AgentMarkdownTone
    let document: AgentMarkdownDocument
    let blocks: [Block]
    let attributedValue: NSAttributedString
    let replacementRange: NSRange
    let isFullReplacement: Bool
    let expectedStablePrefix: String?
    let preservesSelectionOnFullReplacement: Bool

    var replacementValue: NSAttributedString {
        attributedValue.attributedSubstring(from: NSRange(
            location: replacementRange.location,
            length: attributedValue.length - replacementRange.location
        ))
    }

    static func prepare(
        snapshot: StreamingMarkdownSession.PreparedSnapshot,
        previous: AgentMarkdownRenderCommit?,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        images: [String: NSImage] = [:]
    ) -> AgentMarkdownRenderCommit {
        let document = AgentMarkdownDocument(streamingDocument: snapshot.document)
        let reusablePrefixCount = safeReusablePrefixCount(
            snapshot: snapshot,
            document: document,
            previous: previous,
            typography: typography,
            tone: tone
        )
        var values: [NSAttributedString] = []
        values.reserveCapacity(document.preparedBlocks.count)

        for (index, block) in document.preparedBlocks.enumerated() {
            if index < reusablePrefixCount, let previous {
                values.append(previous.blocks[index].attributedValue)
                continue
            }
            let rendered = NativeAgentMarkdownRenderer.render(
                block: block.content,
                typography: typography,
                tone: tone,
                images: images
            )
            if index == 0 {
                values.append(rendered)
            } else {
                let value = NSMutableAttributedString(string: "\n")
                value.append(rendered)
                values.append(NSAttributedString(attributedString: value))
            }
        }

        return assemble(
            snapshot: snapshot,
            typography: typography,
            tone: tone,
            document: document,
            values: values,
            previous: previous,
            reusablePrefixCount: reusablePrefixCount
        )
    }

    func carryingStablePrefix(
        from currentlyApplied: AgentMarkdownRenderCommit
    ) -> AgentMarkdownRenderCommit {
        let reusablePrefixCount = Self.safeReusablePrefixCount(
            snapshot: snapshot,
            document: document,
            previous: currentlyApplied,
            typography: typography,
            tone: tone
        )
        guard reusablePrefixCount > 0 else { return self }

        var values = blocks.map(\.attributedValue)
        for index in 0..<reusablePrefixCount {
            values[index] = currentlyApplied.blocks[index].attributedValue
        }
        return Self.assemble(
            snapshot: snapshot,
            typography: typography,
            tone: tone,
            document: document,
            values: values,
            previous: currentlyApplied,
            reusablePrefixCount: reusablePrefixCount
        )
    }

    private static func assemble(
        snapshot: StreamingMarkdownSession.PreparedSnapshot,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        document: AgentMarkdownDocument,
        values: [NSAttributedString],
        previous: AgentMarkdownRenderCommit?,
        reusablePrefixCount: Int
    ) -> AgentMarkdownRenderCommit {

        let output = NSMutableAttributedString()
        var blocks: [Block] = []
        blocks.reserveCapacity(values.count)
        for (block, value) in zip(document.preparedBlocks, values) {
            let range = NSRange(location: output.length, length: value.length)
            output.append(value)
            blocks.append(.init(
                id: block.id,
                sourceRange: block.sourceRange,
                attributedValue: value,
                attributedRange: range
            ))
        }

        let replacementLocation: Int
        let isFullReplacement: Bool
        if reusablePrefixCount > 0, let previous {
            replacementLocation = blocks[reusablePrefixCount - 1].attributedRange.upperBound
            isFullReplacement = false
            precondition(replacementLocation <= previous.attributedValue.length)
        } else {
            replacementLocation = 0
            isFullReplacement = true
        }
        let previousLength = previous?.attributedValue.length ?? 0
        let expectedStablePrefix = isFullReplacement ? nil : previous.map {
            ($0.attributedValue.string as NSString).substring(to: replacementLocation)
        }

        return AgentMarkdownRenderCommit(
            source: snapshot.source,
            generation: snapshot.generation,
            contentVersion: snapshot.contentVersion,
            snapshot: snapshot,
            typography: typography,
            tone: tone,
            document: document,
            blocks: blocks,
            attributedValue: NSAttributedString(attributedString: output),
            replacementRange: NSRange(
                location: replacementLocation,
                length: max(0, previousLength - replacementLocation)
            ),
            isFullReplacement: isFullReplacement,
            expectedStablePrefix: expectedStablePrefix,
            preservesSelectionOnFullReplacement: previous?.source == snapshot.source
        )
    }

    private init(
        source: String,
        generation: Int,
        contentVersion: Int,
        snapshot: StreamingMarkdownSession.PreparedSnapshot,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone,
        document: AgentMarkdownDocument,
        blocks: [Block],
        attributedValue: NSAttributedString,
        replacementRange: NSRange,
        isFullReplacement: Bool,
        expectedStablePrefix: String?,
        preservesSelectionOnFullReplacement: Bool
    ) {
        self.source = source
        self.generation = generation
        self.contentVersion = contentVersion
        self.snapshot = snapshot
        self.typography = typography
        self.tone = tone
        self.document = document
        self.blocks = blocks
        self.attributedValue = attributedValue
        self.replacementRange = replacementRange
        self.isFullReplacement = isFullReplacement
        self.expectedStablePrefix = expectedStablePrefix
        self.preservesSelectionOnFullReplacement = preservesSelectionOnFullReplacement
    }

    private static func safeReusablePrefixCount(
        snapshot: StreamingMarkdownSession.PreparedSnapshot,
        document: AgentMarkdownDocument,
        previous: AgentMarkdownRenderCommit?,
        typography: WorkspaceTypography,
        tone: AgentMarkdownTone
    ) -> Int {
        guard let previous,
              snapshot.contentVersion > previous.contentVersion,
              previous.typography == typography,
              previous.tone == tone,
              snapshot.document.stablePrefixCount > 0,
              snapshot.document.stablePrefixCount <= previous.blocks.count,
              snapshot.document.stablePrefixCount <= document.preparedBlocks.count
        else { return 0 }

        let count = snapshot.document.stablePrefixCount
        for index in 0..<count {
            let old = previous.blocks[index]
            let new = document.preparedBlocks[index]
            guard old.id == new.id,
                  old.sourceRange == new.sourceRange,
                  previous.document.preparedBlocks[index] == new,
                  old.attributedRange.location == (index == 0
                    ? 0
                    : previous.blocks[index - 1].attributedRange.upperBound)
            else { return 0 }
        }
        return count
    }
}

private extension NSRange {
    var upperBound: Int { location + length }
}
