import Foundation
import Testing

@testable import RePossessFormat

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

/// The author UUID of the fixtures.
private let fixtureAuthor = UUID(uuidString: "00000000-0000-4000-8000-0000000000a0")!

/// A Markdown fixture, with invented text.
private func fixture(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appending(path: name), encoding: .utf8)
}

private func styles(_ paragraphs: [StyledParagraph]) -> [String] {
    paragraphs.map { "\($0.style.name) \($0.text)" }
}

@Suite struct MarkdownTests {
    @Test func everyStyleInTheShortNote() throws {
        #expect(styles(parseMarkdown(try fixture("a-styles.md"))) == styles(aStyles))
    }

    @Test func theShortNoteMatchesRmscenesPage() throws {
        let expected = [UInt8](try Data(contentsOf: fixtures.appending(path: "rmscene-a-styles.rm")))
        let paragraphs = parseMarkdown(try fixture("a-styles.md"))
        #expect(try writeBlocks(textPageBlocks(paragraphs, authorUUID: fixtureAuthor)) == expected)
    }

    @Test func codeAndTablesBecomeBodyLines() throws {
        let plain = styles(parseMarkdown(try fixture("c-code-table.md")))
        #expect(plain.contains("PLAIN     return \"Hello, \\(name)!\""))
        #expect(plain.contains("PLAIN | Plum | Purple | 12 |"))
        #expect(!plain.contains { $0.contains("---") })
        #expect(plain.last == "PLAIN The end.")
    }

    @Test(arguments: [
        ("snake_case_name stays", "snake_case_name stays"),
        ("_italic_ and __bold__", "italic and bold"),
        ("`a*b*c` keeps its stars", "a*b*c keeps its stars"),
        ("![alt text](x.png) and [link](https://example.com/a_b)", "alt text and link"),
        ("~~struck~~ and \\*escaped\\*", "struck and *escaped*"),
    ])
    func inlineMarkdownBecomesPlainText(input: String, expected: String) {
        #expect(inlineText(input) == expected)
    }

    @Test func listContinuationLinesJoinTheItem() {
        let paragraphs = parseMarkdown("- one\n  more of one\n- two\n\nbody")
        #expect(styles(paragraphs) == ["BULLET one more of one", "BULLET two", "PLAIN body"])
    }

    @Test func sectionsLayoutStartsAPageAtEachLevelTwoHeading() throws {
        let pages = layOutPages(parseMarkdown(try fixture("b-long.md")), .sections)
        #expect(pages.count == 11)
        #expect(pages[0].map(\.style) == [.heading, .plain])
        for (i, page) in pages.dropFirst().enumerated() {
            #expect(page[0].style == .bold)
            #expect(page[0].text.hasPrefix("Section \(i + 1):"))
        }
        // A page with only headings does not break.
        let headingsOnly = layOutPages(parseMarkdown("# T\n\n## A\n\nbody\n\n## B\n\nmore"), .sections)
        #expect(headingsOnly.map { $0.map(\.text) } == [["T", "A", "body"], ["B", "more"]])
    }
}

@Suite struct MarkdownNotebookTests {
    @Test func oneGrowingPageOrOnePagePerSection() throws {
        let markdown = try fixture("b-long.md")
        let single = try MarkdownNotebook(title: "rePossess test b1", markdown: markdown)
        #expect(single.pageCount == 1)
        let paged = try MarkdownNotebook(title: "rePossess test b2", markdown: markdown, paginate: true)
        #expect(paged.pageCount == 11)
        #expect(single.paragraphCount == paged.paragraphCount)

        let archive = try RmdocArchive(data: paged.rmdoc)
        #expect(archive.documentID == paged.documentID)
        #expect(archive.files.filter { $0.name.hasSuffix(".rm") }.count == 11)
        let metadata = try DocumentMetadata(
            parsing: archive.files.first { $0.name.hasSuffix(".metadata") }!.data
        )
        #expect(metadata.visibleName == "rePossess test b2" && metadata.parent == "")
        #expect(metadata.lastModified != nil)
    }

    @Test func pagesReadBackToTheMappedParagraphs() throws {
        let markdown = try fixture("a-styles.md")
        let notebook = try MarkdownNotebook(title: "  rePossess test a  ", markdown: markdown)
        #expect(notebook.title == "rePossess test a")
        let archive = try RmdocArchive(data: notebook.rmdoc)
        let page = try #require(archive.files.first { $0.name.hasSuffix(".rm") })
        let read = pageContent([UInt8](page.data)).paragraphs.map { "\($0.style.name) \($0.plain)" }
        #expect(read == styles(aStyles))
    }

    @Test func refusesBadInputs() throws {
        #expect(throws: NotebookError.emptyTitle) { try MarkdownNotebook(title: "  ", markdown: "text") }
        #expect(throws: NotebookError.titleHasControlCharacters) {
            try MarkdownNotebook(title: "two\nlines", markdown: "text")
        }
        #expect(throws: NotebookError.titleTooLong(201)) {
            try MarkdownNotebook(title: String(repeating: "a", count: 201), markdown: "text")
        }
        #expect(throws: NotebookError.noText) { try MarkdownNotebook(title: "t", markdown: "\n---\n\n") }
        #expect(throws: NotebookError.markdownTooLong(100_001)) {
            try MarkdownNotebook(title: "t", markdown: String(repeating: "a", count: 100_001))
        }
        let sections = (1 ... 201).map { "## S\($0)\n\nbody" }.joined(separator: "\n\n")
        #expect(throws: NotebookError.tooManyPages(201)) {
            try MarkdownNotebook(title: "t", markdown: sections, paginate: true)
        }
    }
}
