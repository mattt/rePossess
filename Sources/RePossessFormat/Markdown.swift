// The Markdown subset from spike 4 (spikes/04-notebook-writer/Sources/Notebook/Markdown.swift).
// Phase 3 keeps one rule for code blocks and tables: each line becomes a Body paragraph,
// which is what the tablet showed for spike 4's file c on 2026-10-25.

import Foundation

/// Maps a small subset of Markdown to tablet paragraphs.
///
/// The rules follow reMarkdown's `push_markdown` and the design's Markdown table:
///
/// - `#` becomes Title (rmscene's HEADING); `##` to `######` become Subheading (BOLD).
/// - A paragraph becomes one Body (PLAIN) paragraph; its lines are joined with spaces.
/// - `-`, `*`, and `+` items become BULLET; items indented two or more spaces become BULLET2.
/// - `- [ ]` and `- [x]` become CHECKBOX and CHECKBOX_CHECKED, at any indent.
/// - `1.` items become Body text with the number written out.
/// - Emphasis, inline code, links, and images become plain text; footnotes are dropped.
/// - Block quotes become Body text; horizontal rules are dropped.
/// - Each line of a code block, and each row of a table apart from its delimiter row,
///   becomes a Body paragraph as it is, with a code line's indent kept.
///
/// This is a line-based parser, not CommonMark.
func parseMarkdown(_ markdown: String) -> [StyledParagraph] {
    var out: [StyledParagraph] = []
    var paragraphLines: [String] = []
    var openItem: Int?  // index in `out` of a list item that takes continuation lines
    var fence: String?
    var inFootnote = false

    func flush() {
        if !paragraphLines.isEmpty {
            out.append(StyledParagraph(.plain, inlineText(paragraphLines.joined(separator: " "))))
            paragraphLines = []
        }
    }

    let normalized = markdown.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
    for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine).replacing("\t", with: "    ")
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let marker = fence {
            if trimmed.hasPrefix(marker) {
                fence = nil
            } else if !trimmed.isEmpty {
                out.append(StyledParagraph(.plain, trimTrailing(line)))
            }
            continue
        }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            flush()
            openItem = nil
            fence = String(trimmed.prefix(3))
            continue
        }
        if trimmed.isEmpty {
            flush()
            openItem = nil
            inFootnote = false
            continue
        }
        if inFootnote {
            continue
        }
        if let m = trimmed.wholeMatch(of: #/(#{1,6})\s+(.*?)(\s+#+)?/#) {
            flush()
            openItem = nil
            let level = m.1.count
            out.append(StyledParagraph(level == 1 ? .heading : .bold, inlineText(String(m.2)), headingLevel: level))
            continue
        }
        if trimmed.wholeMatch(of: #/([-*_])(\s*\1){2,}/#) != nil {
            flush()
            openItem = nil
            continue
        }
        if trimmed.hasPrefix("|") {
            flush()
            openItem = nil
            let isDelimiterRow = trimmed.allSatisfy { "|-: ".contains($0) }
            if !isDelimiterRow {
                out.append(StyledParagraph(.plain, trimmed))
            }
            continue
        }
        if trimmed.firstMatch(of: #/^\[\^[^\]]+\]:/#) != nil {
            flush()
            openItem = nil
            inFootnote = true
            continue
        }
        if let m = line.wholeMatch(of: #/( *)[-*+]\s+(\[[ xX]\]\s+)?(.*)/#) {
            flush()
            let indent = m.1.count
            let style: ParagraphStyle
            if let box = m.2 {
                style = box.hasPrefix("[ ]") ? .checkbox : .checkboxChecked
            } else {
                style = indent >= 2 ? .bullet2 : .bullet
            }
            out.append(StyledParagraph(style, inlineText(String(m.3))))
            openItem = out.count - 1
            continue
        }
        if let m = line.wholeMatch(of: #/ *(\d+)[.)]\s+(.*)/#) {
            flush()
            out.append(StyledParagraph(.plain, "\(m.1). " + inlineText(String(m.2))))
            openItem = out.count - 1
            continue
        }
        var content = trimmed
        if let m = trimmed.wholeMatch(of: #/>\s?(.*)/#) {
            content = String(m.1)
        }
        if let index = openItem {
            out[index].text += " " + inlineText(content)
        } else {
            paragraphLines.append(content)
        }
    }
    flush()
    return out
}

private func trimTrailing(_ s: String) -> String {
    var s = Substring(s)
    while let last = s.last, last == " " { s.removeLast() }
    return String(s)
}

/// Turns inline Markdown into plain text.
/// Code spans keep their content as it is; the rest loses its markers.
func inlineText(_ s: String) -> String {
    var result = ""
    var rest = Substring(s)
    while let m = rest.firstMatch(of: #/`([^`]*)`/#) {
        result += stripInline(String(rest[..<m.range.lowerBound]))
        result += m.1
        rest = rest[m.range.upperBound...]
    }
    result += stripInline(String(rest))
    return result
}

private func stripInline(_ s: String) -> String {
    // Protect escaped characters as private-use scalars (U+E000 plus the ASCII value),
    // so that the emphasis rules do not see them, and restore them at the end.
    var s = s.replacing(#/\\([\\`*_{}\[\]()#+\-.!|>~])/#) { m in
        String(Character(Unicode.Scalar(0xE000 + m.1.unicodeScalars.first!.value)!))
    }
    s = s.replacing(#/!\[([^\]]*)\]\([^)]*\)/#) { String($0.1) }
    s = s.replacing(#/\[\^[^\]]+\]/#, with: "")
    s = s.replacing(#/\[([^\]]+)\]\([^)]*\)/#) { String($0.1) }
    s = s.replacing(#/\*\*(.+?)\*\*/#) { String($0.1) }
    s = s.replacing(#/(^|\W)__(.+?)__(?=\W|$)/#) { String($0.1) + String($0.2) }
    s = s.replacing(#/~~(.+?)~~/#) { String($0.1) }
    s = s.replacing(#/\*(.+?)\*/#) { String($0.1) }
    s = s.replacing(#/(^|\W)_(.+?)_(?=\W|$)/#) { String($0.1) + String($0.2) }
    return String(
        String.UnicodeScalarView(
            s.unicodeScalars.map { scalar in
                (0xE000 ..< 0xE080).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0xE000)! : scalar
            }
        )
    )
}

/// Why Markdown could not become a notebook.
public enum NotebookError: Error, Equatable, CustomStringConvertible {
    case emptyTitle
    case titleTooLong(Int)
    case titleHasControlCharacters
    case noText
    case markdownTooLong(Int)
    case tooManyPages(Int)

    public var description: String {
        switch self {
        case .emptyTitle: "the title is empty"
        case .titleTooLong(let count):
            "the title has \(count) characters; the limit is \(MarkdownNotebook.maxTitleLength)"
        case .titleHasControlCharacters: "the title has a line break or another control character"
        case .noText: "the Markdown has no text that the notebook can show"
        case .markdownTooLong(let count):
            "the Markdown has \(count) characters; the limit is \(MarkdownNotebook.maxMarkdownLength)"
        case .tooManyPages(let count):
            "the notebook would have \(count) pages; the limit is \(MarkdownNotebook.maxPages)"
        }
    }
}

/// A new notebook with typed text, made from Markdown, as an rmdoc archive.
///
/// The text maps to the tablet's paragraph styles as ``parseMarkdown(_:)`` describes.
/// Without pagination, all the text goes on one page,
/// which the tablet grows downward to fit:
/// spike 4's note of about 3,300 words exported from the tablet as one page 5,651 points tall.
/// With pagination, a new page starts at each `##` heading.
public struct MarkdownNotebook: Sendable {
    /// The longest title, in characters.
    public static let maxTitleLength = 200
    /// The longest Markdown, in characters.
    /// The longest note checked on the tablet had about 18,000 characters on one page (spike 4).
    public static let maxMarkdownLength = 100_000
    /// The most pages. The tablet opened 11 pages in spike 4;
    /// the page order keys past the 11th are unchecked on the tablet.
    public static let maxPages = 200

    /// The document ID inside the archive. The USB interface replaces it;
    /// the cloud keeps it.
    public let documentID: String
    /// The name that the tablet shows.
    public let title: String
    public let pageCount: Int
    public let paragraphCount: Int
    /// The rmdoc archive: `.content`, `.metadata`, and one `.rm` file for each page.
    public let rmdoc: Data

    /// Makes a notebook.
    ///
    /// - Parameters:
    ///   - title: The name on the tablet, 1 to ``maxTitleLength`` characters, on one line.
    ///   - markdown: The text, at most ``maxMarkdownLength`` characters.
    ///   - paginate: Start a new page at each `##` heading, instead of one page that grows.
    ///   - documentID: A lowercase UUID.
    public init(
        title: String,
        markdown: String,
        paginate: Bool = false,
        documentID: String = UUID().uuidString.lowercased(),
        created: Date = Date()
    ) throws {
        let title = try Self.checkedTitle(title)
        guard markdown.count <= Self.maxMarkdownLength else { throw NotebookError.markdownTooLong(markdown.count) }
        let paragraphs = parseMarkdown(markdown)
        guard paragraphs.contains(where: { !$0.text.isEmpty }) else { throw NotebookError.noText }
        let pages = layOutPages(paragraphs, paginate ? .sections : .single)
        guard pages.count <= Self.maxPages else { throw NotebookError.tooManyPages(pages.count) }
        let notebook = Notebook(visibleName: title, pages: pages, documentId: documentID, created: created)
        self.documentID = documentID
        self.title = title
        self.pageCount = pages.count
        self.paragraphCount = paragraphs.count
        self.rmdoc = try notebook.rmdoc()
    }

    /// The title without surrounding spaces, or an error.
    public static func checkedTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw NotebookError.emptyTitle }
        guard trimmed.count <= maxTitleLength else { throw NotebookError.titleTooLong(trimmed.count) }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NotebookError.titleHasControlCharacters
        }
        return trimmed
    }
}
