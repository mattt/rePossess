import Foundation
import Testing

@testable import RePossessFormat

/// Block types 14 and 15, which hold a notebook page's images (see PageImages.swift).
/// The bytes are invented, in the layout of the blocks on a page from 2026-10-25.
@Suite struct ImageTests {
    static let key: ImageKey = Array(1 ... 16)
    static let fileName = "0a0a0a0a-0000-4000-8000-000000000001.png"

    /// Block 14's body: subblock 1 with a count of 1 and one entry with the key,
    /// the file name at timestamp (1, 100), and the unknown subblock 2 at (1, 101).
    static let filesBlock = hex(
        "1c5c000000010c560000000102030405060708090a0b0c0d0e0f101c320000001f01642c2a0000002801306130613061"
            + "30612d303030302d343030302d383030302d3030303030303030303030312e706e672c0a0000001f01652c020000001100"
    )

    /// Block 15's body: parent (1, 104), item (1, 105), and a value of item type 7
    /// with the key at (1, 102), the ID (1, 103), four vertices, and two triangles.
    static let imageBlock = hex(
        "1f01682f01693f00004f000054000000006c85000000071c180000001f01662c100000000102030405060708090a0b0c0d0e0f10"
            + "2f01673c41000000100000e1c300400d4600000000000000000000e14300400d460000803f000000000000e1430036114600"
            + "00803f0000803f0000e1c300361146000000000000803f4c19000000060000000001000000020000000200000003000000"
            + "00000000"
    )

    static func hex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index ..< next], radix: 16)!)
            index = next
        }
        return bytes
    }

    static func block(_ type: UInt8, minVersion: UInt8, currentVersion: UInt8, _ body: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: UInt32(body.count).littleEndian, Array.init) + [0, minVersion, currentVersion, type] + body
    }

    @Test func readsBothBlocks() throws {
        let bytes =
            try writeBlocks([])
            + Self.block(14, minVersion: 3, currentVersion: 3, Self.filesBlock)
            + Self.block(15, minVersion: 2, currentVersion: 2, Self.imageBlock)
        let result = readPage(bytes)
        #expect(!result.blocks.contains { $0 is UnreadableBlock })

        let files = try #require(result.blocks.compactMap { $0 as? ImageFilesBlock }.first)
        #expect(files.entries.count == 1)
        #expect(files.entries[0].key == Self.key)
        #expect(files.entries[0].fileName.value == Self.fileName)
        #expect(files.entries[0].fileName.timestamp == CrdtId(1, 100))
        #expect(files.entries[0].flags?.value == [0x11, 0x00])
        #expect(result.tree.imageFiles[Self.key] == Self.fileName)

        let block = try #require(result.blocks.compactMap { $0 as? SceneImageItemBlock }.first)
        #expect(block.parentId == CrdtId(1, 104))
        #expect(block.item.itemId == CrdtId(1, 105))
        let image = try #require(block.item.value)
        #expect(image.key.value == Self.key)
        #expect(image.unknownId == CrdtId(1, 103))
        #expect(
            image.vertices == [
                ImageVertex(x: -450, y: 9040, u: 0, v: 0), ImageVertex(x: 450, y: 9040, u: 1, v: 0),
                ImageVertex(x: 450, y: 9293.5, u: 1, v: 1), ImageVertex(x: -450, y: 9293.5, u: 0, v: 1),
            ]
        )
        #expect(image.indices == [0, 1, 2, 2, 3, 0])
        // The parent group is not in this bare stream, so the tree skips the item and says so.
        #expect(result.warnings.count == 1)
    }

    @Test func writesTheSameBytes() throws {
        let files = ImageFilesBlock(entries: [
            .init(
                key: Self.key,
                fileName: LwwValue(CrdtId(1, 100), Self.fileName),
                flags: LwwValue(CrdtId(1, 101), [0x11, 0x00])
            )
        ])
        let item = ImageItem(
            key: LwwValue(CrdtId(1, 102), Self.key),
            unknownId: CrdtId(1, 103),
            vertices: [
                ImageVertex(x: -450, y: 9040, u: 0, v: 0), ImageVertex(x: 450, y: 9040, u: 1, v: 0),
                ImageVertex(x: 450, y: 9293.5, u: 1, v: 1), ImageVertex(x: -450, y: 9293.5, u: 0, v: 1),
            ],
            indices: [0, 1, 2, 2, 3, 0]
        )
        let image = SceneImageItemBlock(
            parentId: CrdtId(1, 104),
            item: CrdtSequenceItem(CrdtId(1, 105), CrdtId(0, 0), CrdtId(0, 0), 0, item)
        )
        let header = try writeBlocks([])
        #expect(
            try writeBlocks([files, image])
                == header + Self.block(14, minVersion: 3, currentVersion: 3, Self.filesBlock)
                + Self.block(15, minVersion: 2, currentVersion: 2, Self.imageBlock)
        )
    }

    @Test func pageContentListsImagesWithoutWarnings() throws {
        var page = PageBuilder()
        page.paragraphs = [StyledParagraph(.plain, "The tables follow:")]
        page.images = [
            .init(fileName: "first.png", x: -450, y: 400, width: 900, height: 250),
            .init(fileName: "second.png", x: -450, y: 700, width: 900, height: 300),
        ]
        let content = pageContent(try page.bytes())
        #expect(content.warnings.isEmpty)
        #expect(content.images == ["first.png", "second.png"])
        #expect(content.strokeCount == 0)
        #expect(content.strokeHash == nil)
    }

    @Test func markdownInsertsLinesInReadingOrder() {
        let content = PageContent(paragraphs: [
            TypedParagraph(style: .heading, markdown: "Title", plain: "Title"),
            TypedParagraph(style: .bullet, markdown: "One", plain: "One"),
            TypedParagraph(style: .bullet, markdown: "Two", plain: "Two"),
        ])
        #expect(
            content.markdown(inserting: [(0, "[A]"), (2, "[B]"), (9, "[C]"), (2, "[D]")])
                == "[A]\n\n# Title\n\n- One\n\n[B]\n\n[D]\n\n- Two\n\n[C]"
        )
        #expect(content.markdown(inserting: []) == content.markdown)
    }
}
