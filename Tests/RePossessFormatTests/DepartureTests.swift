import Foundation
import Testing

@testable import RePossessFormat

/// The three places where rePossess departs from rmscene 0.8.0 (docs/design.md, Format).
@Suite struct DepartureTests {
    private func lines(_ result: PageReadResult) throws -> [Line] {
        var lines: [Line] = []
        try visit(result.tree.root) { item in
            if case .line(let line) = item { lines.append(line) }
        }
        return lines
    }

    @Test func unknownToolAndColorKeepTheStroke() throws {
        var page = PageBuilder()
        page.groups = [
            .init(lines: [
                PageBuilder.stroke([(0, 100), (50, 150)], tool: Pen(rawValue: 99), color: PenColor(rawValue: 77))
            ])
        ]
        let result = readPage(try page.bytes())
        #expect(result.warnings.isEmpty)
        #expect(!result.blocks.contains { $0 is UnreadableBlock })
        let line = try #require(try lines(result).first)
        #expect(line.tool.rawValue == 99 && !line.tool.isKnown)
        #expect(line.color.name == "UNKNOWN_77")
        #expect(pageContent(result).strokeCount == 1)
    }

    @Test func optionalColorCheckStopsAtTheBlockEnd() throws {
        // A stroke whose value ends its block, followed by a block of 388 bytes:
        // the length's first bytes, 84 01, read as the tag for index 8, type Byte4.
        // rmscene then reads past the subblock and keeps the stroke as an unreadable block.
        var page = PageBuilder()
        page.groups = [.init(lines: [PageBuilder.stroke([(0, 0), (10, 10)])])]
        var bytes = try page.bytes()
        bytes += [0x84, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x30] + [UInt8](repeating: 0, count: 388)
        let result = readPage(bytes)
        let line = try #require(try lines(result).first)
        #expect(line.colorRGBA == nil)
        #expect(result.blocks.filter { $0 is UnreadableBlock }.count == 1)  // only the invented block type 0x30
        #expect(result.blocks.last?.blockType == 0x30)
    }

    @Test func truncatedPageKeepsWhatWasRead() throws {
        var page = PageBuilder()
        page.paragraphs = [StyledParagraph(.plain, "Kept text")]
        page.groups = [.init(lines: [PageBuilder.stroke([(0, 0), (10, 10)]), PageBuilder.stroke([(5, 5), (9, 9)])])]
        let bytes = try page.bytes()
        let result = readPage(Array(bytes.dropLast(10)))
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("stops early"))
        let content = pageContent(result)
        #expect(content.paragraphs.map(\.plain) == ["Kept text"])
        #expect(content.strokeCount == 1)
        // rmscene's behavior, which the strict reader keeps: the whole page fails.
        #expect(throws: RMSceneError.self) { try readTree(Array(bytes.dropLast(10))) }
    }

    @Test func strokeWithAMissingParentIsSkipped() throws {
        var page = PageBuilder()
        page.groups = [.init(lines: [PageBuilder.stroke([(0, 0), (1, 1)])])]
        var blocks = page.blocks()
        blocks.append(
            SceneItemBlock(
                kind: .line,
                parent: CrdtId(9, 9),
                item: CrdtSequenceItem(CrdtId(3, 1), CrdtId(0, 0), CrdtId(0, 0), 0, .line(PageBuilder.stroke([(2, 2)])))
            )
        )
        let result = readPage(try writeBlocks(blocks))
        #expect(result.warnings.count == 1)
        #expect(pageContent(result).strokeCount == 1)
    }

    @Test func notAPage() {
        let result = readPage(Array("not a page".utf8))
        #expect(result.blocks.isEmpty)
        #expect(result.warnings.count == 1)
    }
}
