import Foundation

enum MarkdownMathScanner {
    struct PreparedMarkdown {
        let markdown: String
        let placeholders: [String: MarkdownMath]
    }

    static func prepare(_ value: String) -> PreparedMarkdown {
        var output = ""
        var placeholders: [String: MarkdownMath] = [:]
        var index = value.startIndex
        var isAtLineStart = true
        var fence: Fence?
        var inlineBacktickCount = 0

        while index < value.endIndex {
            if isAtLineStart, inlineBacktickCount == 0 {
                let line = lineRange(from: index, in: value)
                if let marker = fenceMarker(in: value[line.content]) {
                    let closesFence = fence.map {
                        $0.character == marker.character && marker.count >= $0.count
                    } ?? false
                    if fence == nil || closesFence {
                        output += value[line.complete]
                        fence = closesFence ? nil : marker
                        index = line.complete.upperBound
                        isAtLineStart = true
                        continue
                    }
                }
                if fence != nil {
                    output += value[line.complete]
                    index = line.complete.upperBound
                    isAtLineStart = true
                    continue
                }
            }

            let character = value[index]
            if character == "`" {
                let count = repeatedCharacterCount("`", at: index, in: value)
                let end = value.index(index, offsetBy: count)
                output += value[index..<end]
                if inlineBacktickCount == 0 {
                    inlineBacktickCount = count
                } else if inlineBacktickCount == count {
                    inlineBacktickCount = 0
                }
                index = end
                isAtLineStart = false
                continue
            }

            if inlineBacktickCount == 0, let delimiter = delimiter(at: index, in: value) {
                if let match = match(for: delimiter, from: index, in: value) {
                    var token = "KUBECODEMATHTOKEN\(placeholders.count)END"
                    while value.contains(token) || placeholders[token] != nil { token += "X" }
                    placeholders[token] = compatibleMath(latex: match.latex, display: delimiter.display)
                    output += token
                    index = match.endIndex
                    isAtLineStart = false
                    continue
                }
                if delimiter.opening.first == "\\" {
                    output += delimiter.opening.replacingOccurrences(of: #"\"#, with: #"\\"#)
                    index = value.index(index, offsetBy: delimiter.opening.count)
                    isAtLineStart = false
                    continue
                }
            }

            output.append(character)
            index = value.index(after: index)
            isAtLineStart = character == "\n"
        }

        return .init(markdown: output, placeholders: placeholders)
    }

    private struct Fence {
        let character: Character
        let count: Int
    }

    private struct SourceLine {
        let content: Range<String.Index>
        let complete: Range<String.Index>
    }

    private struct Delimiter {
        let opening: String
        let closing: String
        let display: Bool
        let singleDollar: Bool
    }

    private struct Match {
        let latex: String
        let endIndex: String.Index
    }

    private static func lineRange(from start: String.Index, in value: String) -> SourceLine {
        guard let newline = value[start...].firstIndex(of: "\n") else {
            return .init(content: start..<value.endIndex, complete: start..<value.endIndex)
        }
        return .init(content: start..<newline, complete: start..<value.index(after: newline))
    }

    private static func fenceMarker(in line: Substring) -> Fence? {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }
        guard indentation <= 3, index < line.endIndex,
              line[index] == "`" || line[index] == "~"
        else { return nil }
        let character = line[index]
        var count = 0
        while index < line.endIndex, line[index] == character {
            count += 1
            index = line.index(after: index)
        }
        return count >= 3 ? .init(character: character, count: count) : nil
    }

    private static func repeatedCharacterCount(
        _ character: Character,
        at start: String.Index,
        in value: String
    ) -> Int {
        var index = start
        var count = 0
        while index < value.endIndex, value[index] == character {
            count += 1
            index = value.index(after: index)
        }
        return count
    }

    private static func delimiter(at index: String.Index, in value: String) -> Delimiter? {
        if value[index...].hasPrefix("$$") {
            return .init(opening: "$$", closing: "$$", display: true, singleDollar: false)
        }
        if value[index...].hasPrefix(#"\["#) {
            return .init(opening: #"\["#, closing: #"\]"#, display: true, singleDollar: false)
        }
        if value[index...].hasPrefix(#"\("#) {
            return .init(opening: #"\("#, closing: #"\)"#, display: false, singleDollar: false)
        }
        if value[index] == "$" {
            let next = value.index(after: index)
            if next < value.endIndex, value[next].isNumber { return nil }
            return .init(opening: "$", closing: "$", display: false, singleDollar: true)
        }
        return nil
    }

    private static func match(
        for delimiter: Delimiter,
        from openingIndex: String.Index,
        in value: String
    ) -> Match? {
        let contentStart = value.index(openingIndex, offsetBy: delimiter.opening.count)
        guard contentStart < value.endIndex,
              let closingRange = value.range(of: delimiter.closing, range: contentStart..<value.endIndex)
        else { return nil }

        let content = String(value[contentStart..<closingRange.lowerBound])
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if delimiter.singleDollar,
           content.contains("\n") || content.first?.isWhitespace == true || content.last?.isWhitespace == true {
            return nil
        }
        return .init(
            latex: delimiter.singleDollar ? content : trimmed,
            endIndex: closingRange.upperBound
        )
    }

    private static func compatibleMath(latex: String, display: Bool) -> MarkdownMath {
        let expanded = expandMacros(in: latex)
        let boxedContents = outerBoxContents(in: expanded)
        let body = boxedContents ?? expanded
        let compatible = body
            .replacingOccurrences(of: #"\operatorname*{"#, with: #"\mathrm{"#)
            .replacingOccurrences(of: #"\operatorname{"#, with: #"\mathrm{"#)
        return .init(
            renderSource: compatible,
            source: latex,
            display: display,
            boxed: boxedContents != nil
        )
    }

    private struct Macro {
        let name: String
        let argumentCount: Int
        let replacement: String
    }

    private static let protectedCommands: Set<String> = [
        "begin", "end", "frac", "sqrt", "left", "right", "text", "mathrm",
        "mathbf", "mathit", "mathbb", "mathcal", "operatorname", "boxed",
        "sum", "prod", "int", "lim", "sin", "cos", "tan", "log", "ln",
    ]

    private static func expandMacros(in latex: String) -> String {
        var body = latex
        var macros: [String: Macro] = [:]
        var searchStart = body.startIndex

        while macros.count < 64,
              let commandRange = body.range(of: #"\newcommand"#, range: searchStart..<body.endIndex) {
            guard let parsed = parseMacro(in: body, at: commandRange.lowerBound),
                  !protectedCommands.contains(parsed.macro.name)
            else {
                searchStart = commandRange.upperBound
                continue
            }
            macros[parsed.macro.name] = parsed.macro
            body.removeSubrange(commandRange.lowerBound..<parsed.endIndex)
            searchStart = commandRange.lowerBound
        }

        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<8 {
            let expanded = expandOnePass(body, macros: macros)
            guard expanded != body, expanded.utf8.count <= 16 * 1_024 else { break }
            body = expanded
        }
        return body
    }

    private static func parseMacro(
        in value: String,
        at start: String.Index
    ) -> (macro: Macro, endIndex: String.Index)? {
        var index = value.index(start, offsetBy: #"\newcommand"#.count)
        skipWhitespace(in: value, index: &index)
        guard let nameGroup = bracedGroup(in: value, at: index) else { return nil }
        let name = nameGroup.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.first == "\\", name.dropFirst().allSatisfy(\.isLetter) else { return nil }
        index = nameGroup.endIndex
        skipWhitespace(in: value, index: &index)

        var argumentCount = 0
        if index < value.endIndex, value[index] == "[",
           let close = value[index...].firstIndex(of: "]") {
            let countStart = value.index(after: index)
            guard let count = Int(value[countStart..<close]), (0...2).contains(count) else { return nil }
            argumentCount = count
            index = value.index(after: close)
            skipWhitespace(in: value, index: &index)
        }

        guard let replacement = bracedGroup(in: value, at: index) else { return nil }
        return (
            .init(
                name: String(name.dropFirst()),
                argumentCount: argumentCount,
                replacement: replacement.content
            ),
            replacement.endIndex
        )
    }

    private static func expandOnePass(_ value: String, macros: [String: Macro]) -> String {
        guard !macros.isEmpty else { return value }
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "\\" else {
                output.append(value[index])
                index = value.index(after: index)
                continue
            }
            let nameStart = value.index(after: index)
            var nameEnd = nameStart
            while nameEnd < value.endIndex, value[nameEnd].isLetter {
                nameEnd = value.index(after: nameEnd)
            }
            let name = String(value[nameStart..<nameEnd])
            guard let macro = macros[name] else {
                output += value[index..<nameEnd]
                index = nameEnd
                continue
            }

            var argumentIndex = nameEnd
            var arguments: [String] = []
            var valid = true
            for _ in 0..<macro.argumentCount {
                skipWhitespace(in: value, index: &argumentIndex)
                guard let group = bracedGroup(in: value, at: argumentIndex) else {
                    valid = false
                    break
                }
                arguments.append(group.content)
                argumentIndex = group.endIndex
            }
            guard valid else {
                output += value[index..<nameEnd]
                index = nameEnd
                continue
            }
            var replacement = macro.replacement
            for (offset, argument) in arguments.enumerated() {
                replacement = replacement.replacingOccurrences(of: "#\(offset + 1)", with: argument)
            }
            output += replacement
            index = argumentIndex
        }
        return output
    }

    private static func skipWhitespace(in value: String, index: inout String.Index) {
        while index < value.endIndex, value[index].isWhitespace {
            index = value.index(after: index)
        }
    }

    private static func bracedGroup(
        in value: String,
        at start: String.Index
    ) -> (content: String, endIndex: String.Index)? {
        guard start < value.endIndex, value[start] == "{" else { return nil }
        var index = value.index(after: start)
        var depth = 1
        var escaped = false
        while index < value.endIndex {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(value[value.index(after: start)..<index]), value.index(after: index))
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func outerBoxContents(in latex: String) -> String? {
        let value = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"\boxed{"#
        guard value.hasPrefix(prefix) else { return nil }
        let openingBrace = value.index(value.startIndex, offsetBy: prefix.count - 1)
        var index = value.index(after: openingBrace)
        var depth = 1
        var escaped = false
        while index < value.endIndex {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let remainder = value[value.index(after: index)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard remainder.isEmpty else { return nil }
                    return String(value[value.index(after: openingBrace)..<index])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            index = value.index(after: index)
        }
        return nil
    }
}
