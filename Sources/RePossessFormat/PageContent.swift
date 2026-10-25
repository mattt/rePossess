import CryptoKit
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
    /// A SHA-256 hash of the strokes that draw, in hexadecimal, or `nil` for a page without them.
    ///
    /// It covers each stroke's tool, color, thickness, and points (x, y, and width),
    /// the anchor and x origin of each group, and the page's size,
    /// in the order of the scene tree.
    /// Recognized handwriting is cached under it,
    /// so a page is recognized again only when its strokes change.
    /// Typed text is not in the hash: a stroke group anchored to the text
    /// keeps its hash when the text moves it.
    public var strokeHash: String?
    /// Problems the reader skipped; see ``readPage(_:)``.
    public var warnings: [String]

    public init(
        paragraphs: [TypedParagraph] = [],
        highlights: [String] = [],
        strokeCount: Int = 0,
        strokeHash: String? = nil,
        warnings: [String] = []
    ) {
        self.paragraphs = paragraphs
        self.highlights = highlights
        self.strokeCount = strokeCount
        self.strokeHash = strokeHash
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
    var hasher = StrokeHasher()
    if let size = result.tree.sceneInfo?.paperSize {
        hasher.add("size", UInt64(size.0), UInt64(size.1))
    }
    do {
        try visit(result.tree.root) { item in
            switch item {
            case .line(let line):
                if !line.tool.isEraser, !line.points.isEmpty {
                    content.strokeCount += 1
                    hasher.add(line)
                }
            case .glyphRange(let glyph):
                let text = glyph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { content.highlights.append(text) }
            case .group(let group):
                hasher.add(group)
            }
        }
    } catch {
        content.warnings.append("The strokes could not be read: \(error)")
    }
    if content.strokeCount > 0 { content.strokeHash = hasher.hex }
    return content
}

/// Hashes the strokes of a page for ``PageContent/strokeHash``.
struct StrokeHasher {
    private var hash = SHA256()

    mutating func add(_ tag: String, _ values: UInt64...) {
        hash.update(data: Data(tag.utf8))
        for value in values {
            withUnsafeBytes(of: value.littleEndian) { hash.update(bufferPointer: $0) }
        }
    }

    mutating func add(_ group: Group) {
        add(
            "group",
            group.anchorId?.value.part1 ?? 0,
            group.anchorId?.value.part2 ?? 0,
            UInt64(group.anchorOriginX?.value.bitPattern ?? 0)
        )
    }

    mutating func add(_ line: Line) {
        add(
            "line",
            UInt64(line.tool.rawValue),
            UInt64(line.color.rawValue),
            line.colorRGBA.map { UInt64($0.r) << 24 | UInt64($0.g) << 16 | UInt64($0.b) << 8 | UInt64($0.a) } ?? 0,
            line.thicknessScale.bitPattern,
            UInt64(line.points.count)
        )
        for point in line.points {
            add("", point.x.bitPattern, point.y.bitPattern, UInt64(bitPattern: Int64(point.width)))
        }
    }

    var hex: String {
        hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
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
