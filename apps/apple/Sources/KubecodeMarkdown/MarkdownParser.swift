import Foundation
import Markdown

public enum MarkdownParser {
    public static func parse(_ source: String) -> KubecodeMarkdownDocument {
        guard !source.isEmpty else {
            return .init(source: source, blocks: [])
        }

        let prepared = MarkdownMathScanner.prepare(source)
        let parsed = Document(parsing: prepared.markdown, options: [.disableSmartOpts])
        let blocks = parsed.children.enumerated().compactMap { index, child in
            projectBlock(
                child,
                id: "b\(index)",
                placeholders: prepared.placeholders
            )
        }
        return .init(source: source, blocks: blocks)
    }

    private static func projectBlock(
        _ markup: Markup,
        id: String,
        placeholders: [String: MarkdownMath]
    ) -> MarkdownBlock? {
        let range = sourceRange(markup.range)
        switch markup {
        case let paragraph as Paragraph:
            return .init(
                id: id,
                sourceRange: range,
                kind: .paragraph(projectInlineChildren(paragraph, id: id, placeholders: placeholders))
            )
        case let heading as Heading:
            return .init(
                id: id,
                sourceRange: range,
                kind: .heading(
                    level: heading.level,
                    projectInlineChildren(heading, id: id, placeholders: placeholders)
                )
            )
        case let code as CodeBlock:
            return .init(
                id: id,
                sourceRange: range,
                kind: .codeBlock(language: code.language, code: code.code)
            )
        case let quote as BlockQuote:
            return .init(
                id: id,
                sourceRange: range,
                kind: .blockQuote(projectBlockChildren(quote, id: id, placeholders: placeholders))
            )
        case let list as UnorderedList:
            return .init(
                id: id,
                sourceRange: range,
                kind: .unorderedList(items: projectListItems(list, id: id, placeholders: placeholders))
            )
        case let list as OrderedList:
            return .init(
                id: id,
                sourceRange: range,
                kind: .orderedList(
                    start: Int(list.startIndex),
                    items: projectListItems(list, id: id, placeholders: placeholders)
                )
            )
        case is ThematicBreak:
            return .init(id: id, sourceRange: range, kind: .thematicBreak)
        case let table as Table:
            return .init(
                id: id,
                sourceRange: range,
                kind: .table(projectTable(table, id: id, placeholders: placeholders))
            )
        case let html as HTMLBlock:
            return .init(id: id, sourceRange: range, kind: .rawHTML(html.rawHTML))
        default:
            let children = projectBlockChildren(markup, id: id, placeholders: placeholders)
            if children.count == 1 { return children[0] }
            if !children.isEmpty {
                return .init(id: id, sourceRange: range, kind: .blockQuote(children))
            }
            return nil
        }
    }

    private static func projectBlockChildren(
        _ markup: Markup,
        id: String,
        placeholders: [String: MarkdownMath]
    ) -> [MarkdownBlock] {
        markup.children.enumerated().compactMap { index, child in
            projectBlock(child, id: "\(id).b\(index)", placeholders: placeholders)
        }
    }

    private static func projectListItems(
        _ markup: Markup,
        id: String,
        placeholders: [String: MarkdownMath]
    ) -> [MarkdownListItem] {
        markup.children.enumerated().compactMap { index, child in
            guard let item = child as? ListItem else { return nil }
            let checkbox: MarkdownCheckbox? = switch item.checkbox {
            case .checked?: .checked
            case .unchecked?: .unchecked
            case nil: nil
            }
            return .init(
                id: "\(id).i\(index)",
                checkbox: checkbox,
                blocks: projectBlockChildren(
                    item,
                    id: "\(id).i\(index)",
                    placeholders: placeholders
                )
            )
        }
    }

    private static func projectTable(
        _ table: Table,
        id: String,
        placeholders: [String: MarkdownMath]
    ) -> MarkdownTable {
        let alignments = table.columnAlignments.map { alignment -> MarkdownTable.ColumnAlignment in
            switch alignment {
            case .left?: .left
            case .center?: .center
            case .right?: .right
            case nil: .unspecified
            }
        }
        let headers = table.head.cells.enumerated().map { index, cell in
            projectInlineChildren(cell, id: "\(id).h\(index)", placeholders: placeholders)
        }
        let rows = table.body.rows.enumerated().map { rowIndex, row in
            row.cells.enumerated().map { columnIndex, cell in
                projectInlineChildren(
                    cell,
                    id: "\(id).r\(rowIndex)c\(columnIndex)",
                    placeholders: placeholders
                )
            }
        }
        return .init(columnAlignments: alignments, headers: headers, rows: rows)
    }

    private static func projectInlineChildren(
        _ markup: Markup,
        id: String,
        traits: MarkdownTextTraits = [],
        placeholders: [String: MarkdownMath]
    ) -> [MarkdownInline] {
        markup.children.enumerated().flatMap { index, child in
            projectInline(
                child,
                id: "\(id).n\(index)",
                traits: traits,
                placeholders: placeholders
            )
        }
    }

    private static func projectInline(
        _ markup: Markup,
        id: String,
        traits: MarkdownTextTraits,
        placeholders: [String: MarkdownMath]
    ) -> [MarkdownInline] {
        let range = sourceRange(markup.range)
        switch markup {
        case let text as Text:
            return splitText(
                text.string,
                id: id,
                range: range,
                traits: traits,
                placeholders: placeholders
            )
        case let code as InlineCode:
            return [.init(id: id, sourceRange: range, kind: .code(code.code))]
        case let strong as Strong:
            return projectInlineChildren(
                strong,
                id: id,
                traits: traits.union(.strong),
                placeholders: placeholders
            )
        case let emphasis as Emphasis:
            return projectInlineChildren(
                emphasis,
                id: id,
                traits: traits.union(.emphasis),
                placeholders: placeholders
            )
        case let strike as Strikethrough:
            return projectInlineChildren(
                strike,
                id: id,
                traits: traits.union(.strikethrough),
                placeholders: placeholders
            )
        case let link as Link:
            return [.init(
                id: id,
                sourceRange: range,
                kind: .link(
                    destination: link.destination,
                    title: link.title,
                    children: projectInlineChildren(
                        link,
                        id: id,
                        traits: traits,
                        placeholders: placeholders
                    )
                )
            )]
        case let image as Image:
            let alt = image.children.compactMap { ($0 as? Text)?.string }.joined()
            return [.init(
                id: id,
                sourceRange: range,
                kind: .image(source: image.source, title: image.title, alt: alt)
            )]
        case is SoftBreak:
            return [.init(id: id, sourceRange: range, kind: .softBreak)]
        case is LineBreak:
            return [.init(id: id, sourceRange: range, kind: .lineBreak)]
        case let html as InlineHTML:
            return [.init(id: id, sourceRange: range, kind: .rawHTML(html.rawHTML))]
        default:
            return projectInlineChildren(
                markup,
                id: id,
                traits: traits,
                placeholders: placeholders
            )
        }
    }

    private static func splitText(
        _ value: String,
        id: String,
        range: MarkdownSourceRange?,
        traits: MarkdownTextTraits,
        placeholders: [String: MarkdownMath]
    ) -> [MarkdownInline] {
        guard !placeholders.isEmpty else {
            return value.isEmpty ? [] : [.init(id: id, sourceRange: range, kind: .text(value, traits))]
        }

        var result: [MarkdownInline] = []
        var cursor = value.startIndex
        var part = 0
        while cursor < value.endIndex {
            let next = placeholders.compactMap { token, math -> (Range<String.Index>, MarkdownMath)? in
                guard let match = value.range(of: token, range: cursor..<value.endIndex) else { return nil }
                return (match, math)
            }.min { $0.0.lowerBound < $1.0.lowerBound }
            guard let next else {
                result.append(.init(
                    id: "\(id).p\(part)",
                    sourceRange: range,
                    kind: .text(String(value[cursor...]), traits)
                ))
                break
            }
            if cursor < next.0.lowerBound {
                result.append(.init(
                    id: "\(id).p\(part)",
                    sourceRange: range,
                    kind: .text(String(value[cursor..<next.0.lowerBound]), traits)
                ))
                part += 1
            }
            result.append(.init(
                id: "\(id).p\(part)",
                sourceRange: range,
                kind: .math(next.1)
            ))
            part += 1
            cursor = next.0.upperBound
        }
        return result
    }

    private static func sourceRange(_ range: SourceRange?) -> MarkdownSourceRange? {
        guard let range else { return nil }
        return .init(
            start: .init(line: range.lowerBound.line, column: range.lowerBound.column),
            end: .init(line: range.upperBound.line, column: range.upperBound.column)
        )
    }
}
