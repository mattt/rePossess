import Compression
import Foundation
import Testing

@testable import RePossessFormat

/// Builds a zip archive with deflated entries, as the tablet writes them.
private func deflatedZip(_ files: [(String, Data)]) -> Data {
    var out = Data()
    var central = Data()
    func u16(_ v: Int, _ d: inout Data) { d += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func u32(_ v: UInt32, _ d: inout Data) {
        d += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
    }
    for (name, data) in files {
        var compressed = Data(count: data.count + 1024)
        let n = compressed.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    data.count + 1024,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        compressed = compressed.prefix(n)
        let offset = UInt32(out.count)
        let nameBytes = Data(name.utf8)
        u32(0x0403_4B50, &out)
        u16(20, &out)
        u16(0, &out)
        u16(8, &out)
        u16(0, &out)
        u16(0, &out)
        u32(crc32(data), &out)
        u32(UInt32(compressed.count), &out)
        u32(UInt32(data.count), &out)
        u16(nameBytes.count, &out)
        u16(0, &out)
        out += nameBytes
        out += compressed
        u32(0x0201_4B50, &central)
        u16(20, &central)
        u16(20, &central)
        u16(0, &central)
        u16(8, &central)
        u16(0, &central)
        u16(0, &central)
        u32(crc32(data), &central)
        u32(UInt32(compressed.count), &central)
        u32(UInt32(data.count), &central)
        u16(nameBytes.count, &central)
        for _ in 0 ..< 4 { u16(0, &central) }
        u32(0, &central)
        u32(offset, &central)
        central += nameBytes
    }
    let centralOffset = UInt32(out.count)
    out += central
    u32(0x0605_4B50, &out)
    u16(0, &out)
    u16(0, &out)
    u16(files.count, &out)
    u16(files.count, &out)
    u32(UInt32(central.count), &out)
    u32(centralOffset, &out)
    u16(0, &out)
    return out
}

@Suite struct ZipTests {
    @Test func crc32OfTheCheckString() {
        #expect(crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func readsDeflatedEntries() throws {
        let text = Data(String(repeating: "invented page text ", count: 200).utf8)
        let files = try readZip(deflatedZip([("doc.content", Data("{}".utf8)), ("doc/p1.rm", text)]))
        #expect(files.map(\.name) == ["doc.content", "doc/p1.rm"])
        #expect(files[1].data == text)
    }

    @Test func readsStoredEntries() throws {
        let zip = storedZip(
            [ArchiveFile(name: "a", data: Data([1, 2, 3])), ArchiveFile(name: "b/c", data: Data())],
            modified: Date(timeIntervalSince1970: 1_792_800_000)
        )
        #expect(
            try readZip(zip) == [
                ArchiveFile(name: "a", data: Data([1, 2, 3])), ArchiveFile(name: "b/c", data: Data()),
            ]
        )
    }

    @Test func refusesUnsafePaths() {
        #expect(throws: ZipError.unsafePath("../evil")) {
            try readZip(storedZip([ArchiveFile(name: "../evil", data: Data())], modified: Date()))
        }
        #expect(!isSafeArchivePath("/abs"))
        #expect(!isSafeArchivePath("a//b"))
        #expect(isSafeArchivePath("doc/page.rm"))
    }

    @Test func detectsACorruptEntry() throws {
        var zip = storedZip([ArchiveFile(name: "a", data: Data([1, 2, 3]))], modified: Date())
        zip[31] ^= 0xFF  // the first byte of the stored data, after a 30-byte header and the name
        #expect(throws: ZipError.badCRC("a")) { try readZip(zip) }
        #expect(throws: ZipError.notAZip) { try readZip(Data("not a zip at all, but long enough".utf8)) }
    }
}

@Suite struct DocumentModelTests {
    @Test func contentPagesInIndexOrderWithoutDeletedPages() throws {
        let json = """
            {"fileType": "pdf", "cPages": {"pages": [
              {"id": "p-c", "idx": {"timestamp": "1:2", "value": "bc"}, "redir": {"timestamp": "1:2", "value": 2}},
              {"id": "p-a", "idx": {"timestamp": "1:2", "value": "ba"}, "redir": {"timestamp": "1:2", "value": 0}},
              {"id": "p-x", "idx": {"timestamp": "1:2", "value": "bb"}, "deleted": {"timestamp": "1:3", "value": 1}},
              {"id": "p-new", "idx": {"timestamp": "1:2", "value": "bd"}, "template": {"timestamp": "1:1", "value": "Blank"}}
            ]}, "tags": [{"name": "garden", "timestamp": 1}],
            "pageTags": [{"name": "sketch", "pageId": "p-c", "timestamp": 1}]}
            """
        let content = try DocumentContent(parsing: Data(json.utf8))
        #expect(content.fileType == "pdf")
        #expect(content.pages.map(\.id) == ["p-a", "p-c", "p-new"])
        #expect(content.pages.map(\.number) == [1, 2, 3])
        #expect(content.pages.map(\.sourcePageIndex) == [0, 2, nil])
        #expect(content.pages[2].template == "Blank")
        #expect(content.tags == ["garden"])
        #expect(content.pageTags == ["p-c": ["sketch"]])
    }

    @Test func legacyPagesWithARedirectionMap() throws {
        let json = #"{"fileType": "pdf", "pages": ["a", "b", "c"], "redirectionPageMap": [0, -1, 1], "tags": ["old"]}"#
        let content = try DocumentContent(parsing: Data(json.utf8))
        #expect(content.pages.map(\.sourcePageIndex) == [0, nil, 1])
        #expect(content.tags == ["old"])
    }

    @Test func metadataFields() throws {
        let json =
            #"{"visibleName": "Invented", "type": "CollectionType", "parent": "trash", "lastModified": "1792800000000"}"#
        let metadata = try DocumentMetadata(parsing: Data(json.utf8))
        #expect(metadata.visibleName == "Invented")
        #expect(metadata.kind == .folder)
        #expect(metadata.isTrashed)
        #expect(metadata.lastModified == Date(timeIntervalSince1970: 1_792_800_000))
    }

    @Test func unpackRenamesToTheListedID() throws {
        var page = PageBuilder()
        page.paragraphs = [StyledParagraph(.heading, "Invented title")]
        let builder = DocumentBuilder(id: "aaaa-1111", name: "Invented", pages: [("p1", page), ("p2", nil)])
        let folder = FileManager.default.temporaryDirectory.appending(path: "repossess-format-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try RmdocArchive(data: try builder.rmdoc()).unpack(into: folder, as: "bbbb-2222")
        #expect(try document.metadata().visibleName == "Invented")
        let content = try #require(try document.content())
        #expect(content.pages.map(\.id) == ["p1", "p2"])
        #expect(try document.pageBytes("p1") != nil)
        #expect(try document.pageBytes("p2") == nil)
        #expect(throws: DocumentError.invalidID("../x")) { try document.pageBytes("../x") }
    }
}

@Suite struct PageContentTests {
    @Test func typedTextAsMarkdown() throws {
        let bytes = try writeBlocks(textPageBlocks(aStyles, authorUUID: UUID()))
        let markdown = pageContent(bytes).markdown
        #expect(markdown.hasPrefix("# rePossess test a: styles\n\nThis note was made"))
        #expect(markdown.contains("## Subheading from two hashes\n\nA body paragraph"))
        #expect(
            markdown.contains(
                "- First bullet\n- Second bullet, with a nested list\n  - Nested bullet one\n  - Nested bullet two\n"
                    + "- Third bullet\n- [ ] An open checkbox\n- [x] A checked checkbox\n\n1. A numbered"
            )
        )
    }

    @Test func inlineBoldAndItalic() throws {
        // Formatting codes 1 and 2 turn bold on and off, 3 and 4 italic (rmscene's text.py).
        let items: [CrdtSequenceItem<TextValue>] = [
            CrdtSequenceItem(CrdtId(1, 10), CrdtId(0, 0), CrdtId(0, 0), 0, .string("Plain ")),
            CrdtSequenceItem(CrdtId(1, 20), CrdtId(1, 15), CrdtId(0, 0), 0, .format(1)),
            CrdtSequenceItem(CrdtId(1, 21), CrdtId(1, 20), CrdtId(0, 0), 0, .string("bold")),
            CrdtSequenceItem(CrdtId(1, 30), CrdtId(1, 24), CrdtId(0, 0), 0, .format(2)),
            CrdtSequenceItem(CrdtId(1, 31), CrdtId(1, 30), CrdtId(0, 0), 0, .string(" and ")),
            CrdtSequenceItem(CrdtId(1, 40), CrdtId(1, 35), CrdtId(0, 0), 0, .format(3)),
            CrdtSequenceItem(CrdtId(1, 41), CrdtId(1, 40), CrdtId(0, 0), 0, .string("italic")),
        ]
        let text = Text(items: CrdtSequence(items), styles: [:], posX: -468, posY: 234, width: 936)
        let paragraphs = try TextDocument.fromSceneItem(text).contents
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].contents.map(\.s) == ["Plain ", "bold", " and ", "italic"])
        let typed = typedParagraph(paragraphs[0])
        #expect(typed.markdown == "Plain **bold** and *italic*")
        #expect(typed.plain == "Plain bold and italic")
    }

    @Test func emptyPageHasNoTextOrInk() throws {
        let content = pageContent(try PageBuilder().bytes())
        #expect(!content.hasText && !content.hasInk && content.warnings.isEmpty)
    }

    @Test func erasersDoNotCountAsInk() throws {
        var page = PageBuilder()
        page.groups = [.init(lines: [PageBuilder.stroke([(0, 0), (1, 1)], tool: .eraserArea)])]
        #expect(!pageContent(try page.bytes()).hasInk)
    }
}
