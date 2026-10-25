// Tests ported from rmscene's tests
// (https://github.com/ricklupton/rmscene, v0.8.0).
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see Sources/RePossessFormat/RMScene/LICENSE-rmscene.

import Foundation
import Testing

@testable import RePossessFormat

func hex(_ s: String) -> [UInt8] {
    let digits = Array(s.filter(\.isHexDigit))
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0 ... $0 + 1]), radix: 16)! }
}

/// rmscene's tests/data, if present. Set RMSCENE_CORPUS to override.
private let corpus = URL(
    filePath: ProcessInfo.processInfo.environment["RMSCENE_CORPUS"]
        ?? "/tmp/repossess-spike3/rmscene/tests/data",
    directoryHint: .isDirectory
)
private let hasCorpus = FileManager.default.fileExists(atPath: corpus.appending(path: "Normal_AB.rm").path)

@Suite struct DataStreamTests {
    @Test func varuint() throws {
        #expect(try DataStream([0x00]).readVarUInt() == 0)
        #expect(try DataStream([0x7F]).readVarUInt() == 127)
        #expect(try DataStream([0x80, 0x01]).readVarUInt() == 128)
        #expect(try DataStream([0x84, 0x01]).readVarUInt() == 132)
    }

    @Test func checkTagDoesNotAdvance() throws {
        let stream = DataStream([0x1F, 0x02, 0x19])
        #expect(stream.checkTag(1, .id))
        #expect(!stream.checkTag(2, .id))
        #expect(stream.tell() == 0)
        #expect(try TaggedBlockReader([0x1F, 0x02, 0x19]).readId(1) == CrdtId(2, 0x19))
    }
}

@Suite struct CrdtSequenceTests {
    private func cid(_ k: UInt64) -> CrdtId { CrdtId(k == 0 ? 0 : 1, k) }
    private func item(_ id: UInt64, _ left: UInt64, _ right: UInt64, _ deleted: UInt32, _ value: String)
        -> CrdtSequenceItem<String>
    {
        CrdtSequenceItem(cid(id), cid(left), cid(right), deleted, value)
    }

    @Test func empty() throws {
        #expect(try CrdtSequence<String>([]).keys().isEmpty)
    }

    @Test func overlapping() throws {
        // Two authors insert at the same position; the higher author ID comes first.
        let items = [
            CrdtSequenceItem(CrdtId(1, 1), CrdtId(0, 0), CrdtId(0, 0), 0, "A"),
            CrdtSequenceItem(CrdtId(1, 2), CrdtId(1, 1), CrdtId(0, 0), 0, "Z"),
            CrdtSequenceItem(CrdtId(2, 1), CrdtId(1, 1), CrdtId(1, 2), 0, "12"),
            CrdtSequenceItem(CrdtId(1, 3), CrdtId(1, 1), CrdtId(1, 2), 0, "_"),
        ]
        let seq = CrdtSequence(items)
        #expect(try seq.keys() == [CrdtId(1, 1), CrdtId(2, 1), CrdtId(1, 3), CrdtId(1, 2)])
        #expect(try CrdtSequence(items.reversed()).keys() == seq.keys())
        #expect(try seq.values().joined() == "A12_Z")
    }

    @Test func overlappingSortedById() throws {
        let items = [item(8, 0, 0, 0, "A"), item(9, 8, 0, 0, "B"), item(3, 0, 0, 0, "C")]
        #expect(try CrdtSequence(items).keys() == [cid(3), cid(8), cid(9)])
        #expect(try CrdtSequence(items.reversed()).keys() == [cid(3), cid(8), cid(9)])
    }

    @Test func unknownId() throws {
        let items = [
            item(28, 0, 15, 0, "A"), item(31, 30, 15, 2, ""),
            item(33, 32, 15, 0, "B"), item(15, 0, 0, 0, "C"),
        ]
        #expect(try CrdtSequence(items).keys() == [cid(28), cid(31), cid(33), cid(15)])
        #expect(try CrdtSequence(items.reversed()).keys() == [cid(28), cid(31), cid(33), cid(15)])
    }
}

@Suite struct BlockTests {
    @Test func keepsUnknownDataInMainBlock() throws {
        let data = hex(
            """
            2E000000 0000010D
            1C 06000000 1F 0000 2F 0000
            2C 05000000 1F 0000 21 01
            3C 05000000 1F 0000 21 01
            5C 08000000 7C050000 50070000
            E1 FF
            """
        )
        let blocks = try readBlocks(headerV6 + data)
        let info = try #require(blocks.first as? SceneInfo)
        #expect(info.extraData == [0xE1, 0xFF])
        #expect(info.paperSize?.0 == 0x57C && info.paperSize?.1 == 0x750)
    }

    @Test func keepsUnknownDataInValueSubblock() throws {
        let data = hex(
            """
            59000000 00020205
            1f 0219 2f 021e 3f 0000 4f 0000 54 0000 0000
            6c 4300 0000 03
               14 0f000000 24 00000000 38 00000000 0000f03f 44 00000000
               5c 1c000000 f8fe82c2 f42a30c3 03000800 0000b869 83c2622d 30c30000 08000000
               6f 0001 7f 010f 8f 0101
            """
        )
        let block = try #require(try readBlocks(headerV6 + data).first as? SceneItemBlock)
        #expect(block.kind == .line)
        #expect(block.extraValueData == [0x8F, 0x01, 0x01])
        guard case .line(let line)? = block.item.value else {
            Issue.record("expected a line")
            return
        }
        #expect(line.tool == .ballpoint2)
        #expect(line.points.count == 2)
        #expect(line.moveId == CrdtId(1, 15))
    }

    @Test func errorInBlockIsContained() throws {
        let data = hex(
            """
            06000000 00010103 1f 0219 aa bbcc
            05000000 00010100 1f 0219 21 01
            """
        )
        let blocks = try readBlocks(headerV6 + data)
        #expect(blocks.count == 2)
        let unreadable = try #require(blocks[0] as? UnreadableBlock)
        #expect(unreadable.data == hex("1f0219aabbcc"))
        #expect(unreadable.info.offset == 51 && unreadable.info.blockType == 3)
        let migration = try #require(blocks[1] as? MigrationInfoBlock)
        #expect(migration.migrationId == CrdtId(2, 0x19) && migration.isDevice)
    }
}

@Suite(.enabled(if: hasCorpus, "needs rmscene's tests/data; set RMSCENE_CORPUS"))
struct CorpusTextTests {
    private func lines(_ name: String) throws -> [(ParagraphStyle, String)] {
        let tree = try readTree([UInt8](try Data(contentsOf: corpus.appending(path: name))))
        let text = try #require(tree.rootText)
        return try TextDocument.fromSceneItem(text).contents.map { p in
            let s = p.contents.map { span in
                var s = span.s
                if span.properties["font-weight"] == "bold" { s = "<b>\(s)</b>" }
                if span.properties["font-style"] == "italic" { s = "<i>\(s)</i>" }
                return s
            }.joined()
            return (p.style.value, s)
        }
    }

    private func expectLines(_ name: String, _ expected: [(ParagraphStyle, String)]) throws {
        let actual = try lines(name)
        #expect(actual.map(\.0) == expected.map(\.0))
        #expect(actual.map(\.1) == expected.map(\.1))
    }

    @Test func normalAB() throws {
        try expectLines("Normal_AB.rm", [(.plain, "AB")])
    }

    @Test func list() throws {
        try expectLines(
            "Bold_Heading_Bullet_Normal.rm",
            [
                (.bold, "A"), (.heading, "new line"),
                (.bullet, "B is a letter of the alphabet"), (.plain, "C"),
            ]
        )
    }

    @Test func inlineFormats() throws {
        try expectLines(
            "Normal_A_stroke_2_layers_v3.3.2.rm",
            [
                (.plain, "A"), (.plain, "v3.2.2"),
                (.plain, "Normal <b>bold</b> <i>italic</i>"),
                (.plain, "<b>Bold</b> <i>italic</i> normal"),
                (.bold, "Bold line"), (.plain, "Normal line"), (.heading, "Heading line"),
            ]
        )
    }

    @Test func crdtConcurrentAuthorOrdering() throws {
        try expectLines("test-crdt-ordering.rm", [(.heading, "A12_Z")])
    }

    @Test func everyFileParses() throws {
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "rm" }
        #expect(!files.isEmpty)
        for file in files {
            let blocks = try readBlocks([UInt8](try Data(contentsOf: file)))
            #expect(!blocks.contains { $0 is UnreadableBlock }, "\(file.lastPathComponent)")
        }
    }
}
