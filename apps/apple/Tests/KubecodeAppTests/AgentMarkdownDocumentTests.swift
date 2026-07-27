import Testing
@testable import KubecodeApp

@Suite
struct AgentMarkdownDocumentTests {
    @Test func projects_gfm_blocks_without_flattening_structure() {
        let document = AgentMarkdownDocument(source: """
        # Result

        - first
        - second

        > quoted

        ```swift
        let answer = 42
        ```

        | Name | Value |
        | --- | ---: |
        | answer | 42 |
        """)

        #expect(document.blocks.contains { block in
            if case .heading(level: 1, _) = block { return true }
            return false
        })
        #expect(document.blocks.contains { block in
            if case let .unorderedList(items) = block { return items.count == 2 }
            return false
        })
        #expect(document.blocks.contains { block in
            if case .blockQuote = block { return true }
            return false
        })
        #expect(document.blocks.contains { block in
            if case let .codeBlock(language, code) = block {
                return language == "swift" && code.contains("let answer = 42")
            }
            return false
        })
        #expect(document.blocks.contains { block in
            if case let .table(alignments, headers, rows) = block {
                return alignments == [.unspecified, .right]
                    && headers.count == 2 && rows.count == 1 && rows[0].count == 2
            }
            return false
        })
    }

    @Test func recognizes_native_math_delimiters_and_keeps_code_literal() {
        let document = AgentMarkdownDocument(source: #"""
        Inline $x^2 + y^2$ and \(z = 1\).

        $$\int_0^1 x\,dx$$

        \[E = mc^2\]

        \[\boxed{x + \frac{1}{2}}\]

        `$not_math$`

        ```text
        $also_not_math$
        ```
        """#)

        let math = document.inlineMath
        #expect(math.contains(.init(latex: "x^2 + y^2", display: false)))
        #expect(math.contains(.init(latex: "z = 1", display: false)))
        #expect(math.contains(.init(latex: #"\int_0^1 x\,dx"#, display: true)))
        #expect(math.contains(.init(latex: "E = mc^2", display: true)))
        #expect(math.contains(.init(
            latex: #"x + \frac{1}{2}"#,
            sourceLatex: #"\boxed{x + \frac{1}{2}}"#,
            display: true,
            boxed: true
        )))
        #expect(!math.contains { $0.latex.contains("not_math") })
    }

    @Test func currency_and_streaming_fragments_remain_visible_literal_text() {
        let source = "The price is $5 and the streamed equation is $x +"
        let document = AgentMarkdownDocument(source: source)

        #expect(document.plainText.contains("$5"))
        #expect(document.plainText.contains("$x +"))
        #expect(document.inlineMath.isEmpty)
    }

    @Test func codex_multiline_bracket_formulas_render_as_display_math() {
        let document = AgentMarkdownDocument(source: #"""
        Assume:

        \[
        X=x,\qquad X\sim\operatorname{Binomial}(n,p)
        \]

        Therefore:

        \[
        \hat p\approx N\left(p,\frac{p(1-p)}{n}\right)
        \]
        """#)

        #expect(document.inlineMath == [
            .init(
                latex: #"X=x,\qquad X\sim\mathrm{Binomial}(n,p)"#,
                sourceLatex: #"X=x,\qquad X\sim\operatorname{Binomial}(n,p)"#,
                display: true
            ),
            .init(latex: #"\hat p\approx N\left(p,\frac{p(1-p)}{n}\right)"#, display: true),
        ])
        #expect(!document.plainText.contains("[ X=x"))
    }

    @Test func incomplete_codex_bracket_delimiter_remains_literal_while_streaming() {
        let source = #"Streaming formula: \[\hat p +"#
        let document = AgentMarkdownDocument(source: source)

        #expect(document.inlineMath.isEmpty)
        #expect(document.plainText.contains(#"\[\hat p +"#))
    }

    @Test func codex_display_math_survives_markdown_paragraph_and_run_boundaries() {
        let document = AgentMarkdownDocument(source: #"""
        Binomial likelihood 中，与 $p$ 有关的部分是：

        \[P(X=x\mid p) \propto p^x(1-p)^{n-x}\]

        Beta prior 是：

        \[P(p) \propto p^{\alpha-1}(1-p)^{\beta-1}\]

        更新规则非常直观：

        \[
        \text{新 }\alpha

        = \text{旧 }\alpha + \text{成功次数}
        \]

        `\[code stays literal\]`
        """#)

        #expect(document.inlineMath == [
            .init(latex: "p", display: false),
            .init(latex: #"P(X=x\mid p) \propto p^x(1-p)^{n-x}"#, display: true),
            .init(latex: #"P(p) \propto p^{\alpha-1}(1-p)^{\beta-1}"#, display: true),
            .init(
                latex: #"""
                \text{新 }\alpha

                = \text{旧 }\alpha + \text{成功次数}
                """#,
                display: true
            ),
        ])
        #expect(document.plainText.contains(#"\[code stays literal\]"#))
        #expect(!document.plainText.contains(#"\[P(X=x"#))
    }

    @Test func inline_markdown_styles_and_safe_links_are_projected() {
        let document = AgentMarkdownDocument(
            source: "**bold** *emphasis* ~~removed~~ [Swift](https://swift.org) `code`"
        )
        let runs = document.inlineRuns

        #expect(runs.contains { $0.text == "bold" && $0.traits.contains(.strong) })
        #expect(runs.contains { $0.text == "emphasis" && $0.traits.contains(.emphasis) })
        #expect(runs.contains { $0.text == "removed" && $0.traits.contains(.strikethrough) })
        #expect(runs.contains { $0.text == "code" && $0.traits.contains(.code) })
        #expect(runs.contains { $0.text == "Swift" && $0.destination?.absoluteString == "https://swift.org" })
    }

    @Test func images_are_deduplicated_and_scoped_to_https_or_project_relative_paths() {
        let document = AgentMarkdownDocument(source: """
        ![local](docs/diagram.png)
        ![same local](docs/diagram.png)
        ![remote](https://example.com/result.png)
        ![unsafe](../secret.png)
        ![insecure](http://example.com/result.png)
        """)

        #expect(document.imageLoads.count == 2)
        #expect(document.imageLoads.contains {
            $0.source == "docs/diagram.png"
                && $0.projectPath == "docs/diagram.png"
                && $0.remoteURL == nil
        })
        #expect(document.imageLoads.contains {
            $0.source == "https://example.com/result.png"
                && $0.remoteURL?.host == "example.com"
                && $0.projectPath == nil
        })
    }
}
