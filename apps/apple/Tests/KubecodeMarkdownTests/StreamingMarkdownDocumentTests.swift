import Testing
@testable import KubecodeMarkdown

@Suite
struct StreamingMarkdownDocumentTests {
    @Test func append_only_snapshots_preserve_completed_prefix_block_ids_and_values() throws {
        let initialSource = """
        # Summary

        A completed paragraph.

        Mutable tail
        """
        let initial = StreamingMarkdownDocument(source: initialSource)
        let updated = StreamingMarkdownDocument(
            source: initialSource + " grows",
            previous: initial
        )

        #expect(updated.stablePrefixCount == 2)
        #expect(updated.stablePrefix == Array(initial.blocks.prefix(2)))
        #expect(updated.mutableTail.count == 1)
        #expect(updated.blocks[2].id == initial.blocks[2].id)
        #expect(updated.blocks[2].content != initial.blocks[2].content)
    }

    @Test func closing_emphasis_changes_only_the_mutable_tail() throws {
        let initialSource = """
        # Summary

        A completed paragraph.

        This is **stream
        """
        let initial = StreamingMarkdownDocument(source: initialSource)
        let updated = StreamingMarkdownDocument(
            source: initialSource + "ing**",
            previous: initial
        )

        #expect(updated.stablePrefixCount == 2)
        #expect(updated.blocks[2].id == initial.blocks[2].id)
        #expect(initial.blocks[2].plainText.contains("**stream"))
        let parsed = try #require(updated.blocks[2].parsedBlock)
        #expect(parsed.inlineContent.contains { inline in
            guard case let .text(value, traits) = inline.kind else { return false }
            return value == "streaming" && traits.contains(.strong)
        })
    }

    @Test func closing_fence_changes_only_the_mutable_tail_from_literal_or_paragraph_to_code() throws {
        let initialSource = """
        # Summary

        A completed paragraph.

        ```swift
        let value = 42
        """
        let initial = StreamingMarkdownDocument(source: initialSource)
        let updated = StreamingMarkdownDocument(
            source: initialSource + "\n```",
            previous: initial
        )

        #expect(updated.stablePrefixCount == 2)
        #expect(updated.blocks[2].id == initial.blocks[2].id)
        #expect(initial.blocks[2].literalSource == "```swift\nlet value = 42")
        let parsed = try #require(updated.blocks[2].parsedBlock)
        guard case let .codeBlock(language, code) = parsed.kind else {
            Issue.record("Expected the closed mutable tail to become a code block")
            return
        }
        #expect(language == "swift")
        #expect(code == "let value = 42\n")
    }

    @Test func completing_a_table_changes_only_the_mutable_tail() throws {
        let initialSource = """
        # Summary

        A completed paragraph.

        | Name | Score |
        | ---
        """
        let initial = StreamingMarkdownDocument(source: initialSource)
        let updated = StreamingMarkdownDocument(
            source: initialSource + " | ---: |\n| Ada | 42 |",
            previous: initial
        )

        #expect(updated.stablePrefixCount == 2)
        #expect(updated.blocks[2].id == initial.blocks[2].id)
        let parsed = try #require(updated.blocks[2].parsedBlock)
        guard case let .table(table) = parsed.kind else {
            Issue.record("Expected the completed mutable tail to become a table")
            return
        }
        #expect(table.headers.map(\.plainText) == ["Name", "Score"])
        #expect(table.rows.first?.map(\.plainText) == ["Ada", "42"])
    }

    @Test func incomplete_math_tail_remains_readable_and_closing_it_preserves_prefix_blocks() throws {
        let initialSource = #"""
        # Summary

        A completed paragraph.

        Result: \[x +
        """#
        let initial = StreamingMarkdownDocument(source: initialSource)
        let updated = StreamingMarkdownDocument(
            source: initialSource + #" y\]"#,
            previous: initial
        )

        #expect(updated.stablePrefixCount == 2)
        #expect(initial.blocks[2].plainText.contains(#"\[x +"#))
        #expect(updated.blocks[2].id == initial.blocks[2].id)
        let parsed = try #require(updated.blocks[2].parsedBlock)
        #expect(parsed.inlineContent.contains { inline in
            guard case let .math(math) = inline.kind else { return false }
            return math.source == "x + y" && math.display
        })
    }

    @Test func malformed_tail_falls_back_to_visible_literal_content() {
        let literalTail = """
        ````text
        ``` remains content
        界🙂
        """
        let document = StreamingMarkdownDocument(source: """
        # Stable

        \(literalTail)
        """)

        #expect(document.blocks.count == 2)
        #expect(document.blocks.last?.literalSource == literalTail)
        #expect(document.blocks.last?.plainText == literalTail)
        #expect(document.blocks.last?.sourceRange?.start.line == 3)
    }

    @Test func literal_fence_tail_preserves_unicode_and_crlf_exactly() {
        let source = "# Stable\r\n\r\n```text\r\n界🙂\r\n"
        let document = StreamingMarkdownDocument(source: source)

        #expect(document.blocks.last?.literalSource == "```text\r\n界🙂\r\n")
        #expect(document.blocks.last?.sourceRange?.start.line == 3)
        #expect(document.blocks.last?.sourceRange?.end.line == 5)
    }

    @Test func nested_list_fence_preserves_the_complete_container_projection() throws {
        let document = StreamingMarkdownDocument(source: """
        - Before the fence

          ```swift
          let value = 42
        """)

        let block = try #require(document.blocks.first)
        #expect(document.blocks.count == 1)
        #expect(block.literalSource == nil)
        #expect(block.sourceRange?.start.line == 1)
        #expect(block.plainText.contains("Before the fence"))
        #expect(block.plainText.contains("let value = 42"))
    }

    @Test func raw_html_container_fence_preserves_content_before_the_fence() throws {
        let document = StreamingMarkdownDocument(source: """
        <div>
          ```text
          visible content
        """)

        let block = try #require(document.blocks.first)
        #expect(document.blocks.count == 1)
        #expect(block.literalSource == nil)
        #expect(block.sourceRange?.start.line == 1)
        #expect(block.plainText.contains("<div>"))
        #expect(block.plainText.contains("visible content"))
    }

    @Test func deterministic_block_identity_is_independent_of_parse_task_timing() {
        let source = """
        Same paragraph.

        Same paragraph.

        Same paragraph.
        """
        let first = StreamingMarkdownDocument(source: source)
        let second = StreamingMarkdownDocument(source: source)

        #expect(first.blocks.map(\.id) == second.blocks.map(\.id))
        #expect(Set(first.blocks.map(\.id)).count == 3)
        #expect(first.blocks.map(\.plainText) == second.blocks.map(\.plainText))
    }

    @Test func non_append_edits_never_reuse_a_stale_prefix() {
        let initial = StreamingMarkdownDocument(source: """
        # Original

        Same body.
        """)
        let edited = StreamingMarkdownDocument(
            source: """
            # Edited

            Same body.
            """,
            previous: initial
        )

        #expect(edited.stablePrefixCount == 0)
        #expect(edited.mutableTail == edited.blocks)
    }

    @Test func identical_snapshots_do_not_claim_append_only_prefix_reuse() {
        let source = """
        # Stable

        Same body.
        """
        let initial = StreamingMarkdownDocument(source: source)
        let repeated = StreamingMarkdownDocument(source: source, previous: initial)

        #expect(repeated.stablePrefixCount == 0)
        #expect(repeated.mutableTail == repeated.blocks)
    }
}

private extension Array where Element == MarkdownInline {
    var plainText: String {
        map(\.plainText).joined()
    }
}
