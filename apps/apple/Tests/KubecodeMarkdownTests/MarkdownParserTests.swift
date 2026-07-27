import Testing
@testable import KubecodeMarkdown

@Suite
struct MarkdownParserTests {
    @Test func parses_commonmark_and_gfm_structure() {
        let document = MarkdownParser.parse("""
        # Result

        3. first
        4. second

        - [x] shipped
          - [ ] follow up

        | Name | Score |
        | :--- | ---: |
        | Ada | 42 |

        ![diagram](https://example.com/diagram.png "Architecture")

        <details>literal HTML</details>
        """)

        #expect(document.blocks.contains { block in
            guard case .heading(level: 1, _) = block.kind else { return false }
            return true
        })
        #expect(document.blocks.contains { block in
            guard case let .orderedList(start, items) = block.kind else { return false }
            return start == 3 && items.count == 2
        })
        #expect(document.blocks.contains { block in
            guard case let .unorderedList(items) = block.kind,
                  items.first?.checkbox == .checked,
                  case let .unorderedList(children) = items.first?.blocks.last?.kind
            else { return false }
            return children.first?.checkbox == .unchecked
        })
        #expect(document.blocks.contains { block in
            guard case let .table(table) = block.kind else { return false }
            return table.columnAlignments == [.left, .right]
                && table.headers.count == 2
                && table.rows.count == 1
        })
        #expect(document.inlineContent.contains { inline in
            guard case let .image(source, title, alt) = inline.kind else { return false }
            return source == "https://example.com/diagram.png"
                && title == "Architecture"
                && alt == "diagram"
        })
        #expect(document.blocks.contains { block in
            guard case let .rawHTML(value) = block.kind else { return false }
            return value.contains("<details>")
        })
    }

    @Test func parses_styles_links_breaks_and_code() {
        let document = MarkdownParser.parse("""
        **bold** *emphasis* ~~removed~~ `code` <https://swift.org>  
        next

        ```swift
        let answer = 42
        ```
        """)

        #expect(document.inlineContent.contains { inline in
            guard case let .text(value, traits) = inline.kind else { return false }
            return value == "bold" && traits.contains(.strong)
        })
        #expect(document.inlineContent.contains { inline in
            guard case let .link(destination, _, children) = inline.kind else { return false }
            return destination == "https://swift.org" && children.plainText == "https://swift.org"
        })
        #expect(document.inlineContent.contains { inline in
            if case .lineBreak = inline.kind { return true }
            return false
        })
        #expect(document.blocks.contains { block in
            guard case let .codeBlock(language, code) = block.kind else { return false }
            return language == "swift" && code.contains("let answer = 42")
        })
    }

    @Test func parses_math_without_interpreting_code_or_currency() {
        let document = MarkdownParser.parse(#"""
        Inline $x^2$ and \(y + 1\).

        \[\operatorname{Var}(X) = \frac{1}{n}\]

        `$not_math$` and $5 remain literal.
        """#)

        #expect(document.math == [
            .init(renderSource: "x^2", source: "x^2", display: false),
            .init(renderSource: "y + 1", source: "y + 1", display: false),
            .init(
                renderSource: #"\mathrm{Var}(X) = \frac{1}{n}"#,
                source: #"\operatorname{Var}(X) = \frac{1}{n}"#,
                display: true
            ),
        ])
        #expect(document.plainText.contains("$not_math$"))
        #expect(document.plainText.contains("$5"))
    }

    @Test func incomplete_math_remains_literal() {
        let source = #"Streaming \[x +"#
        let document = MarkdownParser.parse(source)

        #expect(document.math.isEmpty)
        #expect(document.plainText.contains(source))
    }

    @Test func expands_bounded_formula_macros_but_preserves_provider_source() throws {
        let document = MarkdownParser.parse(#"""
        \[
        \newcommand{\vect}[1]{\mathbf{#1}}
        \vect{x} + \vect{y}
        \]
        """#)
        let math = try #require(document.math.first)

        #expect(math.renderSource == #"\mathbf{x} + \mathbf{y}"#)
        #expect(math.source.contains(#"\newcommand{\vect}"#))
    }

    @Test func remote_image_policy_only_accepts_credential_free_https_urls() {
        #expect(MarkdownResourcePolicy.remoteImageURL("https://example.com/image.png")?.host == "example.com")
        #expect(MarkdownResourcePolicy.remoteImageURL("http://example.com/image.png") == nil)
        #expect(MarkdownResourcePolicy.remoteImageURL("file:///tmp/image.png") == nil)
        #expect(MarkdownResourcePolicy.remoteImageURL("data:image/png;base64,AAAA") == nil)
        #expect(MarkdownResourcePolicy.remoteImageURL("https://user:secret@example.com/image.png") == nil)
        #expect(MarkdownResourcePolicy.projectRelativeImagePath("docs/diagram%20one.png") == "docs/diagram one.png")
        #expect(MarkdownResourcePolicy.projectRelativeImagePath("../secret.png") == nil)
        #expect(MarkdownResourcePolicy.projectRelativeImagePath("/absolute.png") == nil)
    }
}

private extension Array where Element == MarkdownInline {
    var plainText: String {
        map(\.plainText).joined()
    }
}
