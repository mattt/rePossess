// Ported from rmscene's text.py
// (https://github.com/ricklupton/rmscene, v0.8.0).
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see LICENSE-rmscene in this directory.

/// Expand a text item into single-character items.
///
/// Each text item's ID identifies its first character;
/// the later characters' IDs are implicit.
/// Characters are Unicode scalars, as Python's `str` iterates code points.
func expandTextItem(_ item: CrdtSequenceItem<TextValue>) throws -> [CrdtSequenceItem<TextValue>] {
    let chars: [String]
    let deletedLength: UInt32
    if item.deletedLength > 0 {
        guard item.value == .string("") else {
            throw RMSceneError.assertion("deleted text item has a value")
        }
        chars = Array(repeating: "", count: Int(item.deletedLength))
        deletedLength = 1
    } else if case .format = item.value {
        return [item]
    } else if case .string(let s) = item.value {
        chars = s.unicodeScalars.map { String($0) }
        deletedLength = 0
    } else {
        chars = []
        deletedLength = 0
    }

    if chars.isEmpty {
        return []  // rmscene warns: unexpected empty text item
    }

    var result: [CrdtSequenceItem<TextValue>] = []
    var itemId = item.itemId
    var leftId = item.leftId
    for c in chars.dropLast() {
        let rightId = CrdtId(itemId.part1, itemId.part2 &+ 1)
        result.append(CrdtSequenceItem(itemId, leftId, rightId, deletedLength, .string(c)))
        leftId = itemId
        itemId = rightId
    }
    result.append(CrdtSequenceItem(itemId, leftId, item.rightId, deletedLength, .string(chars.last!)))
    return result
}

/// Expand a sequence of text items into single-character items.
func expandTextItems(_ items: [CrdtSequenceItem<TextValue>]) throws -> [CrdtSequenceItem<TextValue>] {
    try items.flatMap(expandTextItem)
}

/// String with CRDT IDs for its characters, and properties for the whole span.
public struct CrdtStr: Sendable {
    public var s = ""
    public var i: [CrdtId] = []
    public var properties: [String: String] = [:]
}

/// Paragraph of text.
public struct Paragraph: Sendable {
    public var contents: [CrdtStr]
    public var startId: CrdtId
    public var style = LwwValue(CrdtId(0, 0), ParagraphStyle.plain)

    public var text: String { contents.map(\.s).joined() }
}

public struct TextDocument: Sendable {
    public var contents: [Paragraph]

    /// Extract spans of text with their formatting and character IDs.
    /// This uses the inline formatting introduced in software 3.3.2.
    public static func fromSceneItem(_ text: Text) throws -> TextDocument {
        // Expand from strings to characters.
        let charItems = CrdtSequence(try expandTextItems(text.items.sequenceItems()))
        var keys = try charItems.keys()[...]
        var properties = ["font-weight": "normal", "font-style": "normal"]

        func handleFormattingCode(_ code: UInt32) {
            if code == 1 {
                properties["font-weight"] = "bold"
            } else if code == 2 {
                properties["font-weight"] = "normal"
            }
            if code == 3 {
                properties["font-style"] = "italic"
            } else if code == 4 {
                properties["font-style"] = "normal"
            }
            // rmscene warns about every code other than 3 and 4 here.
        }

        func parseParagraphContents() -> (CrdtId, [CrdtStr]) {
            let startId: CrdtId
            if let first = keys.first, charItems[first] == .string("\n") {
                startId = keys.removeFirst()
            } else {
                startId = endMarker
            }
            var contents: [CrdtStr] = []
            while let key = keys.first {
                switch charItems[key]! {
                case .format(let code):
                    handleFormattingCode(code)
                case .string("\n"):
                    return (startId, contents)  // end of paragraph
                case .string(let char):
                    // Start a new string if the text properties have changed.
                    if contents.last?.properties != properties {
                        contents.append(CrdtStr(properties: properties))
                    }
                    contents[contents.count - 1].s += char
                    contents[contents.count - 1].i.append(key)
                }
                keys.removeFirst()
            }
            return (startId, contents)
        }

        var paragraphs: [Paragraph] = []
        while !keys.isEmpty {
            let (startId, contents) = parseParagraphContents()
            if let style = text.styles[startId] {
                paragraphs.append(Paragraph(contents: contents, startId: startId, style: style))
            } else {
                paragraphs.append(Paragraph(contents: contents, startId: startId))
            }
        }
        return TextDocument(contents: paragraphs)
    }
}
