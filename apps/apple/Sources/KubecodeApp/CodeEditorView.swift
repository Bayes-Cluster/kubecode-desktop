import AppKit
import SwiftUI
import STTextView

enum CodeSyntaxLanguage: Equatable {
    case swift, rust, javascript, typescript, python, json, markdown, shell, yaml, toml, css, html
    case plainText

    static func detect(path: String) -> Self {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["makefile", "dockerfile"].contains(name) { return .shell }
        return switch ext {
        case "swift": .swift
        case "rs": .rust
        case "js", "jsx", "mjs", "cjs": .javascript
        case "ts", "tsx": .typescript
        case "py", "pyi": .python
        case "json", "jsonc": .json
        case "md", "mdx", "markdown": .markdown
        case "sh", "bash", "zsh", "fish": .shell
        case "yaml", "yml": .yaml
        case "toml": .toml
        case "css", "scss", "sass", "less": .css
        case "html", "htm", "xml", "svg": .html
        default: .plainText
        }
    }

    static func detect(languageIdentifier: String?) -> Self {
        guard let identifier = languageIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !identifier.isEmpty
        else { return .plainText }
        return switch identifier {
        case "swift": .swift
        case "rust", "rs": .rust
        case "javascript", "js", "jsx", "mjs", "cjs": .javascript
        case "typescript", "ts", "tsx": .typescript
        case "python", "py": .python
        case "json", "jsonc": .json
        case "markdown", "md", "mdx": .markdown
        case "shell", "sh", "bash", "zsh", "fish", "console": .shell
        case "yaml", "yml": .yaml
        case "toml": .toml
        case "css", "scss", "sass", "less": .css
        case "html", "xml", "svg": .html
        default: .plainText
        }
    }
}

enum CodeSyntaxHighlighter {
    static func attributedString(_ text: String, path: String, font: NSFont) -> NSAttributedString {
        attributedString(text, language: .detect(path: path), font: font)
    }

    static func attributedString(
        _ text: String,
        languageIdentifier: String?,
        font: NSFont
    ) -> NSAttributedString {
        attributedString(
            text,
            language: .detect(languageIdentifier: languageIdentifier),
            font: font
        )
    }

    private static func attributedString(
        _ text: String,
        language: CodeSyntaxLanguage,
        font: NSFont
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.18
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        guard language != .plainText, text.utf16.count < 1_000_000 else { return result }

        switch language {
        case .markdown:
            apply(#"(?m)^#{1,6}\s+.*$"#, color: .systemBlue, to: result)
            apply(#"`[^`]+`"#, color: .systemPink, to: result)
            apply(#"\[[^\]]+\]\([^\)]+\)"#, color: .systemTeal, to: result)
            apply(#"(?m)^\s*(?:[-*+] |\d+\. ).*$"#, color: .secondaryLabelColor, to: result)
        case .json:
            apply(#"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, color: .systemBlue, to: result)
            apply(#"\"(?:\\.|[^\"\\])*\""#, color: .systemGreen, to: result)
            apply(#"\b(?:true|false|null)\b"#, color: .systemPurple, to: result)
            applyNumbers(to: result)
        case .yaml, .toml:
            apply(#"(?m)^\s*[A-Za-z0-9_.-]+(?=\s*[:=])"#, color: .systemBlue, to: result)
            applyStrings(to: result)
            applyNumbers(to: result)
            apply(#"(?m)\s+#.*$"#, color: .secondaryLabelColor, to: result)
        case .html:
            apply(#"</?[A-Za-z][^>]*>"#, color: .systemBlue, to: result)
            apply(#"\"(?:\\.|[^\"\\])*\""#, color: .systemGreen, to: result)
            apply(#"(?s)<!--.*?-->"#, color: .secondaryLabelColor, to: result)
        case .css:
            apply(#"(?m)[.#]?[A-Za-z_-][A-Za-z0-9_-]*(?=\s*\{)"#, color: .systemBlue, to: result)
            apply(#"(?m)[A-Za-z-]+(?=\s*:)"#, color: .systemTeal, to: result)
            applyStrings(to: result)
            applyNumbers(to: result)
            apply(#"(?s)/\*.*?\*/"#, color: .secondaryLabelColor, to: result)
        default:
            applyKeywords(for: language, to: result)
            applyNumbers(to: result)
            applyStrings(to: result)
            applyComments(for: language, to: result)
        }
        return result
    }

    private static func applyKeywords(for language: CodeSyntaxLanguage, to text: NSMutableAttributedString) {
        let keywords: String
        switch language {
        case .swift:
            keywords = "actor|associatedtype|async|await|break|case|catch|class|continue|default|defer|do|else|enum|extension|false|for|func|guard|if|import|in|init|let|nil|protocol|repeat|return|self|static|struct|switch|throw|throws|true|try|typealias|var|where|while"
        case .rust:
            keywords = "as|async|await|break|const|continue|crate|dyn|else|enum|extern|false|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|static|struct|super|trait|true|type|unsafe|use|where|while"
        case .python:
            keywords = "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield"
        case .javascript, .typescript:
            keywords = "as|async|await|break|case|catch|class|const|continue|default|delete|do|else|enum|export|extends|false|finally|for|from|function|if|implements|import|in|instanceof|interface|let|new|null|of|private|protected|public|return|static|super|switch|this|throw|true|try|type|typeof|undefined|var|void|while|yield"
        case .shell:
            keywords = "case|do|done|elif|else|esac|fi|for|function|if|in|select|then|until|while"
        default:
            return
        }
        apply("\\b(?:\(keywords))\\b", color: .systemPurple, to: text)
    }

    private static func applyStrings(to text: NSMutableAttributedString) {
        apply(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: .systemGreen, to: text)
    }

    private static func applyNumbers(to text: NSMutableAttributedString) {
        apply(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, color: .systemOrange, to: text)
    }

    private static func applyComments(for language: CodeSyntaxLanguage, to text: NSMutableAttributedString) {
        if [.swift, .rust, .javascript, .typescript].contains(language) {
            apply(#"(?s)/\*.*?\*/|(?m)//.*$"#, color: .secondaryLabelColor, to: text)
        } else if [.python, .shell].contains(language) {
            apply(#"(?m)#.*$"#, color: .secondaryLabelColor, to: text)
        }
    }

    private static func apply(_ pattern: String, color: NSColor, to text: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: text.length)
        regex.enumerateMatches(in: text.string, range: range) { match, _, _ in
            guard let match else { return }
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

struct NativeFindRequest: Equatable {
    private(set) var sequence = 0
    private(set) var action: NSTextFinder.Action = .showFindInterface

    mutating func send(_ action: NSTextFinder.Action) {
        sequence += 1
        self.action = action
    }
}

struct CodeEditorView: View {
    @Binding var text: String
    let path: String
    let findRequest: NativeFindRequest
    @AppStorage("appearance.codeFont") private var codeFont = "SF Mono"

    init(
        text: Binding<String>,
        path: String,
        findRequest: NativeFindRequest = NativeFindRequest()
    ) {
        _text = text
        self.path = path
        self.findRequest = findRequest
    }

    private var font: NSFont {
        NSFont(name: codeFont, size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    var body: some View {
        NativeCodeEditorView(
            text: $text,
            path: path,
            font: font,
            findRequest: findRequest
        )
        .clipped()
        .accessibilityLabel("Code editor")
    }
}

enum CodeEditorLayoutMetrics {
    static let minimumGutterWidth: CGFloat = 44
    static let trailingContentInset: CGFloat = 24
    static let measurementExtent: CGFloat = 10_000_000

    static func contentWidth(for text: NSAttributedString, gutterWidth: CGFloat) -> CGFloat {
        let textBounds = text.boundingRect(
            with: NSSize(width: measurementExtent, height: measurementExtent),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(textBounds.width)
            + max(gutterWidth, minimumGutterWidth)
            + trailingContentInset
    }
}

final class KubecodeCodeTextView: STTextView {
    private(set) var minimumDocumentWidth: CGFloat = 0

    func updateMinimumDocumentWidth(_ width: CGFloat) {
        minimumDocumentWidth = max(0, width)
        let viewportWidth = enclosingScrollView?.contentView.bounds.width ?? 0
        super.setFrameSize(NSSize(
            width: max(minimumDocumentWidth, viewportWidth),
            height: frame.height
        ))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let viewportWidth = enclosingScrollView?.contentView.bounds.width ?? 0
        super.setFrameSize(NSSize(
            width: max(newSize.width, max(minimumDocumentWidth, viewportWidth)),
            height: newSize.height
        ))
    }
}

private struct NativeCodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let path: String
    let font: NSFont
    let findRequest: NativeFindRequest

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = KubecodeCodeTextView.scrollableTextView()
        scrollView.automaticallyAdjustsContentInsets = false
        let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.contentInsets = zeroInsets
        scrollView.scrollerInsets = zeroInsets
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = true

        let textView = scrollView.documentView as! KubecodeCodeTextView
        textView.textDelegate = context.coordinator
        textView.isHorizontallyResizable = true
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.highlightSelectedLine = true
        textView.showsLineNumbers = true
        textView.gutterView?.font = font
        textView.gutterView?.textColor = .secondaryLabelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isIncrementalSearchingEnabled = true
        textView.textSelection = NSRange()
        context.coordinator.applyDocument(to: textView)
        context.coordinator.lastFindSequence = findRequest.sequence
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let textView = scrollView.documentView as! KubecodeCodeTextView
        let fontChanged = textView.font != font
        if fontChanged {
            textView.font = font
            textView.gutterView?.font = font
        }
        if textView.text != text || context.coordinator.lastPath != path || fontChanged {
            context.coordinator.applyDocument(to: textView)
        }
        if context.coordinator.lastFindSequence != findRequest.sequence {
            context.coordinator.performFind(findRequest.action, in: textView)
            context.coordinator.lastFindSequence = findRequest.sequence
        }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        var parent: NativeCodeEditorView
        var isApplyingAttributes = false
        var lastPath: String?
        var lastFindSequence = 0
        private var highlightTask: Task<Void, Never>?

        init(parent: NativeCodeEditorView) {
            self.parent = parent
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard !isApplyingAttributes,
                  let textView = notification.object as? KubecodeCodeTextView
            else { return }
            parent.text = textView.text ?? ""
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard let self, let textView, !Task.isCancelled else { return }
                applyAttributes(to: textView)
            }
        }

        func applyDocument(to textView: KubecodeCodeTextView) {
            isApplyingAttributes = true
            let highlighted = CodeSyntaxHighlighter.attributedString(
                parent.text,
                path: parent.path,
                font: parent.font
            )
            textView.attributedText = highlighted
            updateDocumentWidth(highlighted, in: textView)
            lastPath = parent.path
            isApplyingAttributes = false
        }

        private func applyAttributes(to textView: KubecodeCodeTextView) {
            guard let storage = (textView.textContentManager as? NSTextContentStorage)?.textStorage else {
                return
            }
            let highlighted = CodeSyntaxHighlighter.attributedString(
                storage.string,
                path: parent.path,
                font: parent.font
            )
            guard highlighted.string == storage.string else { return }

            isApplyingAttributes = true
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            storage.beginEditing()
            highlighted.enumerateAttributes(
                in: NSRange(location: 0, length: highlighted.length)
            ) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
            undoManager?.enableUndoRegistration()
            updateDocumentWidth(highlighted, in: textView)
            lastPath = parent.path
            isApplyingAttributes = false
        }

        private func updateDocumentWidth(
            _ highlighted: NSAttributedString,
            in textView: KubecodeCodeTextView
        ) {
            textView.updateMinimumDocumentWidth(CodeEditorLayoutMetrics.contentWidth(
                for: highlighted,
                gutterWidth: textView.gutterView?.frame.width ?? 0
            ))
        }

        func performFind(_ action: NSTextFinder.Action, in textView: STTextView) {
            let menuItem = NSMenuItem()
            menuItem.tag = action.rawValue
            textView.window?.makeFirstResponder(textView)
            textView.performTextFinderAction(menuItem)
        }
    }
}
