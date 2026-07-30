import AppKit

@MainActor
enum NativeMarkdownSuffixApplier {
    enum Result: Equatable {
        case replacedAll
        case replacedSuffix(NSRange)
        case unchanged
    }

    static func apply(
        _ commit: AgentMarkdownRenderCommit,
        to textView: NativeAgentMarkdownTextView
    ) -> Result {
        guard let storage = textView.textStorage else { return .unchanged }
        if storage.isEqual(to: commit.attributedValue) { return .unchanged }

        let selection = textView.selectedRange()
        if commit.isFullReplacement
            || commit.replacementRange.location > storage.length
            || NSMaxRange(commit.replacementRange) > storage.length
            || NSMaxRange(commit.replacementRange) != storage.length
            || !stablePrefixMatches(commit, storage: storage)
        {
            storage.setAttributedString(commit.attributedValue)
            if commit.preservesSelectionOnFullReplacement,
               selection.location != NSNotFound,
               NSMaxRange(selection) <= storage.length
            {
                textView.setSelectedRange(selection)
            } else {
                restoreSelection(
                    selection,
                    replacementStart: 0,
                    newLength: storage.length,
                    in: textView
                )
            }
            return .replacedAll
        }

        storage.replaceCharacters(
            in: commit.replacementRange,
            with: commit.replacementValue
        )
        restoreSelection(
            selection,
            replacementStart: commit.replacementRange.location,
            newLength: storage.length,
            in: textView
        )
        return .replacedSuffix(commit.replacementRange)
    }

    private static func stablePrefixMatches(
        _ commit: AgentMarkdownRenderCommit,
        storage: NSTextStorage
    ) -> Bool {
        guard let expected = commit.expectedStablePrefix,
              commit.replacementRange.location <= storage.length
        else { return false }
        return (storage.string as NSString).substring(
            to: commit.replacementRange.location
        ) == expected
    }

    private static func restoreSelection(
        _ selection: NSRange,
        replacementStart: Int,
        newLength: Int,
        in textView: NativeAgentMarkdownTextView
    ) {
        guard selection.location != NSNotFound else { return }
        if NSMaxRange(selection) <= replacementStart {
            textView.setSelectedRange(NSRange(
                location: min(selection.location, newLength),
                length: min(selection.length, max(0, newLength - selection.location))
            ))
        } else {
            textView.setSelectedRange(NSRange(
                location: min(replacementStart, newLength),
                length: 0
            ))
        }
    }
}
