import Foundation

/// One paragraph of typed text, with its tablet style.
public struct TypedParagraph: Sendable, Equatable {
    public var style: ParagraphStyle
    /// The text, with inline bold and italic as Markdown.
    public var markdown: String
    /// The text without formatting.
    public var plain: String

    public init(style: ParagraphStyle, markdown: String, plain: String) {
        self.style = style
        self.markdown = markdown
        self.plain = plain
    }
}

/// What a page holds, as rePossess indexes and shows it.
public struct PageContent: Sendable, Equatable {
    /// The typed text, paragraph by paragraph.
    public var paragraphs: [TypedParagraph]
    /// The text of highlights on the page, such as on a PDF page.
    public var highlights: [String]
    /// The strokes that draw: every visible stroke except erasers.
    public var strokeCount: Int
    /// Problems the reader skipped; see ``readPage(_:)``.
    public var warnings: [String]

    public init(
        paragraphs: [TypedParagraph] = [],
        highlights: [String] = [],
        strokeCount: Int = 0,
        warnings: [String] = []
    ) {
        self.paragraphs = paragraphs
        self.highlights = highlights
        self.strokeCount = strokeCount
        self.warnings = warnings
    }

    /// Whether the page has handwriting or drawings.
    public var hasInk: Bool { strokeCount > 0 }

    /// Whether the page has typed text.
    public var hasText: Bool { paragraphs.contains { !$0.plain.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// The typed text as Markdown.
    ///
    /// Title is `#`, Subheading is `##`, bullets are `-` and nested `-`,
    /// and checkboxes are task list items.
    /// Body paragraphs are separated by blank lines, list items are not,
    /// and empty paragraphs are dropped.
    public var markdown: String {
        var out = ""
        var previousWasList = false
        for paragraph in paragraphs {
            let text = paragraph.markdown.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            let (prefix, isList): (String, Bool) =
                switch paragraph.style {
                case .heading: ("# ", false)
                case .bold: ("## ", false)
                case .bullet: ("- ", true)
                case .bullet2: ("  - ", true)
                case .checkbox: ("- [ ] ", true)
                case .checkboxChecked: ("- [x] ", true)
                case .plain, .basic: ("", false)
                }
            if !out.isEmpty {
                out += (isList && previousWasList) ? "\n" : "\n\n"
            }
            out += prefix + text
            previousWasList = isList
        }
        return out
    }

    /// The text that search indexes: typed text without Markdown, then highlights.
    public var searchText: String {
        (paragraphs.map(\.plain) + highlights).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Reads a page's typed text, highlights, and strokes.
///
/// The page is read with ``readPage(_:)``, which never throws;
/// whatever it could not read is in `warnings`.
public func pageContent(_ bytes: [UInt8]) -> PageContent {
    pageContent(readPage(bytes))
}

/// Reads typed text, highlights, and strokes from a page that has been read.
public func pageContent(_ result: PageReadResult) -> PageContent {
    var content = PageContent(warnings: result.warnings)
    if let text = result.tree.rootText {
        do {
            content.paragraphs = try TextDocument.fromSceneItem(text).contents.map(typedParagraph)
        } catch {
            content.warnings.append("The typed text could not be read: \(error)")
        }
    }
    do {
        try visit(result.tree.root) { item in
            switch item {
            case .line(let line):
                if !line.tool.isEraser, !line.points.isEmpty { content.strokeCount += 1 }
            case .glyphRange(let glyph):
                let text = glyph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { content.highlights.append(text) }
            case .group:
                break
            }
        }
    } catch {
        content.warnings.append("The strokes could not be read: \(error)")
    }
    return content
}

/// Calls `body` for every item under `group`, skipping hidden groups and deleted items.
public func visit(_ group: Group, _ body: (SceneItem) throws -> Void) throws {
    guard group.visible.value else { return }
    for item in try group.children.values() {
        guard let item else { continue }
        try body(item)
        if case .group(let child) = item {
            try visit(child, body)
        }
    }
}

func typedParagraph(_ paragraph: Paragraph) -> TypedParagraph {
    var markdown = ""
    var plain = ""
    for span in paragraph.contents {
        plain += span.s
        let bold = span.properties["font-weight"] == "bold"
        let italic = span.properties["font-style"] == "italic"
        markdown += emphasize(span.s, bold: bold, italic: italic)
    }
    return TypedParagraph(style: paragraph.style.value, markdown: markdown, plain: plain)
}

/// Wraps text in Markdown emphasis, keeping its outer spaces outside the markers.
private func emphasize(_ s: String, bold: Bool, italic: Bool) -> String {
    guard bold || italic else { return s }
    let core = s.trimmingCharacters(in: .whitespaces)
    guard !core.isEmpty else { return s }
    let leading = String(s.prefix { $0 == " " })
    let trailing = String(s.reversed().prefix { $0 == " " })
    let marker = bold && italic ? "***" : (bold ? "**" : "*")
    return leading + marker + core + marker + trailing
}
