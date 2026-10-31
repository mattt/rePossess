import Foundation
import Testing

@testable import RePossessFormat

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

/// The author UUID of the fixtures.
private let fixtureAuthor = UUID(uuidString: "00000000-0000-4000-8000-0000000000a0")!

/// The paragraphs of `a-styles.md`, from which rmscene wrote `rmscene-a-styles.rm`.
/// The text is invented.
let aStyles: [StyledParagraph] = [
    StyledParagraph(.heading, "rePossess test a: styles"),
    StyledParagraph(.plain, "This note was made by rePossess spike 4 to test typed-text styles. You can delete it."),
    StyledParagraph(.bold, "Subheading from two hashes"),
    StyledParagraph(
        .plain,
        "A body paragraph with bold, italic, inline code, and a link, all written as plain text. "
            + "Its two source lines join into one paragraph."
    ),
    StyledParagraph(.bold, "Subheading from three hashes"),
    StyledParagraph(.bullet, "First bullet"),
    StyledParagraph(.bullet, "Second bullet, with a nested list"),
    StyledParagraph(.bullet2, "Nested bullet one"),
    StyledParagraph(.bullet2, "Nested bullet two"),
    StyledParagraph(.bullet, "Third bullet"),
    StyledParagraph(.checkbox, "An open checkbox"),
    StyledParagraph(.checkboxChecked, "A checked checkbox"),
    StyledParagraph(.plain, "1. A numbered item keeps its number as Body text"),
    StyledParagraph(.plain, "2. A second numbered item"),
    StyledParagraph(.plain, "A block quote becomes Body text."),
    StyledParagraph(.plain, "A footnote reference is dropped, and so is its note."),
    StyledParagraph(.plain, "Last line: accents and symbols é, ü, ß, and an en dash –."),
]

@Suite struct WriterTests {
    private func read(_ bytes: [UInt8]) -> [String] {
        pageContent(bytes).paragraphs.map { "\($0.style.name) \($0.plain)" }
    }

    @Test func simpleTextDocumentMatchesRmsceneBytes() throws {
        let expected = [UInt8](try Data(contentsOf: fixtures.appending(path: "rmscene-simple.rm")))
        let bytes = try writeBlocks(simpleTextDocument("Hello\nworld, café 🍐", authorUUID: fixtureAuthor))
        #expect(bytes == expected)
    }

    @Test func styledPageMatchesRmsceneBytes() throws {
        let expected = [UInt8](try Data(contentsOf: fixtures.appending(path: "rmscene-a-styles.rm")))
        #expect(try writeBlocks(textPageBlocks(aStyles, authorUUID: fixtureAuthor)) == expected)
    }

    @Test func styledPageReadsBack() throws {
        let bytes = try writeBlocks(textPageBlocks(aStyles, authorUUID: UUID()))
        #expect(read(bytes) == aStyles.map { "\($0.style.name) \($0.text)" })
    }

    @Test func charactersOutsideTheBMPKeepLaterStylesInPlace() throws {
        let paragraphs = [
            StyledParagraph(.heading, "Pears 🍐🍐"),
            StyledParagraph(.bullet, "naïve 𝄞"),
            StyledParagraph(.checkboxChecked, "done"),
        ]
        let bytes = try writeBlocks(textPageBlocks(paragraphs, authorUUID: UUID()))
        #expect(read(bytes) == paragraphs.map { "\($0.style.name) \($0.text)" })
    }

    @Test func roundTripOfARmscenePageKeepsItsBytes() throws {
        let expected = [UInt8](try Data(contentsOf: fixtures.appending(path: "rmscene-a-styles.rm")))
        let blocks = try readBlocks(expected).map { $0 as! any WritableBlock }
        #expect(try writeBlocks(blocks) == expected)
    }

    @Test func strokesAndHighlightsRoundTrip() throws {
        var page = PageBuilder()
        page.groups = [
            .init(lines: [
                PageBuilder.stroke([(1.5, 2.5), (3, 4)], tool: .fineliner2, color: .blue),
                Line(
                    color: .highlight,
                    tool: .highlighter2,
                    points: [Point(x: 0, y: 0, speed: 1, direction: 2, width: 30, pressure: 4)],
                    thicknessScale: 1,
                    colorRGBA: RGBA(r: 1, g: 2, b: 3, a: 4)
                ),
            ])
        ]
        page.highlights = [
            GlyphRange(length: 4, text: "Kept", color: .yellow, rectangles: [Rectangle(x: 1, y: 2, w: 3, h: 4)])
        ]
        let bytes = try page.bytes()
        let blocks = try readBlocks(bytes)
        #expect(!blocks.contains { $0 is UnreadableBlock })
        #expect(try writeBlocks(blocks.map { $0 as! any WritableBlock }) == bytes)
        let content = pageContent(bytes)
        #expect(content.strokeCount == 2)
        #expect(content.highlights == ["Kept"])
    }

    @Test func notebookArchiveFiles() throws {
        let notebook = Notebook(
            visibleName: "rePossess test",
            pages: [[StyledParagraph(.plain, "one")], [StyledParagraph(.plain, "two")]],
            documentId: "doc",
            pageIds: ["p1", "p2"],
            authorUUID: fixtureAuthor,
            created: Date(timeIntervalSince1970: 1_792_800_000)
        )
        let archive = try RmdocArchive(data: try notebook.rmdoc())
        #expect(archive.files.map(\.name) == ["doc.content", "doc.metadata", "doc/p1.rm", "doc/p2.rm"])
        #expect(archive.documentID == "doc")
        let content = try DocumentContent(parsing: archive.files[0].data)
        #expect(content.pages.map(\.id) == ["p1", "p2"])
        #expect(pageIndex(25) == "bz" && pageIndex(26) == "ca")
    }
}
