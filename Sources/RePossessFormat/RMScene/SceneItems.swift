// Ported from rmscene's scene_items.py and scene_tree.py
// (https://github.com/ricklupton/rmscene, v0.8.0).
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see LICENSE-rmscene in this directory.

/// An item stored in the scene tree.
/// rmscene uses a `SceneItem` base class; Swift uses an enum.
public enum SceneItem {
    case group(Group)
    case line(Line)
    case glyphRange(GlyphRange)
}

/// A group of nested items. Groups represent layers.
///
/// `anchorId` refers to a text character that gives the group's anchor y-position.
/// A reference type, because the tree fills in a group after its parent links to it.
public final class Group {
    public let nodeId: CrdtId
    public var children = CrdtSequence<SceneItem?>()
    public var label = LwwValue(CrdtId(0, 0), "")
    public var visible = LwwValue(CrdtId(0, 0), true)
    public var anchorId: LwwValue<CrdtId>?
    public var anchorType: LwwValue<UInt8>?
    public var anchorThreshold: LwwValue<Float>?
    public var anchorOriginX: LwwValue<Float>?

    public init(nodeId: CrdtId) { self.nodeId = nodeId }
}

/// A stroke or highlight color index.
///
/// rePossess departs from rmscene here: an unknown value stays a number,
/// so that a color from a newer tablet keeps its stroke on the page.
/// rmscene raises `ValueError` and drops the whole stroke.
public struct PenColor: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let black = PenColor(rawValue: 0)
    public static let gray = PenColor(rawValue: 1)
    public static let white = PenColor(rawValue: 2)
    public static let yellow = PenColor(rawValue: 3)
    public static let green = PenColor(rawValue: 4)
    public static let pink = PenColor(rawValue: 5)
    public static let blue = PenColor(rawValue: 6)
    public static let red = PenColor(rawValue: 7)
    public static let grayOverlap = PenColor(rawValue: 8)
    /// All highlight colors share this value; the color is in `colorRGBA`.
    public static let highlight = PenColor(rawValue: 9)
    public static let green2 = PenColor(rawValue: 10)
    public static let cyan = PenColor(rawValue: 11)
    public static let magenta = PenColor(rawValue: 12)
    public static let yellow2 = PenColor(rawValue: 13)

    private static let names: [UInt32: String] = [
        0: "BLACK", 1: "GRAY", 2: "WHITE", 3: "YELLOW", 4: "GREEN", 5: "PINK",
        6: "BLUE", 7: "RED", 8: "GRAY_OVERLAP", 9: "HIGHLIGHT", 10: "GREEN_2",
        11: "CYAN", 12: "MAGENTA", 13: "YELLOW_2",
    ]

    /// Whether rmscene 0.8.0 knows this value.
    public var isKnown: Bool { Self.names[rawValue] != nil }

    /// The rmscene enum member name, or `UNKNOWN_<value>`.
    public var name: String { Self.names[rawValue] ?? "UNKNOWN_\(rawValue)" }
}

/// A stroke's tool.
///
/// rePossess departs from rmscene here: an unknown value stays a number,
/// so that a tool from a newer tablet keeps its stroke on the page.
public struct Pen: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let paintbrush1 = Pen(rawValue: 0)
    public static let pencil1 = Pen(rawValue: 1)
    public static let ballpoint1 = Pen(rawValue: 2)
    public static let marker1 = Pen(rawValue: 3)
    public static let fineliner1 = Pen(rawValue: 4)
    public static let highlighter1 = Pen(rawValue: 5)
    public static let eraser = Pen(rawValue: 6)
    public static let mechanicalPencil1 = Pen(rawValue: 7)
    public static let eraserArea = Pen(rawValue: 8)
    public static let paintbrush2 = Pen(rawValue: 12)
    public static let mechanicalPencil2 = Pen(rawValue: 13)
    public static let pencil2 = Pen(rawValue: 14)
    public static let ballpoint2 = Pen(rawValue: 15)
    public static let marker2 = Pen(rawValue: 16)
    public static let fineliner2 = Pen(rawValue: 17)
    public static let highlighter2 = Pen(rawValue: 18)
    public static let caligraphy = Pen(rawValue: 21)
    public static let shader = Pen(rawValue: 23)

    private static let names: [UInt32: String] = [
        0: "PAINTBRUSH_1", 1: "PENCIL_1", 2: "BALLPOINT_1", 3: "MARKER_1", 4: "FINELINER_1",
        5: "HIGHLIGHTER_1", 6: "ERASER", 7: "MECHANICAL_PENCIL_1", 8: "ERASER_AREA",
        12: "PAINTBRUSH_2", 13: "MECHANICAL_PENCIL_2", 14: "PENCIL_2", 15: "BALLPOINT_2",
        16: "MARKER_2", 17: "FINELINER_2", 18: "HIGHLIGHTER_2", 21: "CALIGRAPHY", 23: "SHADER",
    ]

    /// Whether rmscene 0.8.0 knows this value.
    public var isKnown: Bool { Self.names[rawValue] != nil }

    public var isHighlighter: Bool { self == .highlighter1 || self == .highlighter2 }

    public var isEraser: Bool { self == .eraser || self == .eraserArea }

    /// The rmscene enum member name, or `UNKNOWN_<value>`.
    public var name: String { Self.names[rawValue] ?? "UNKNOWN_\(rawValue)" }
}

public struct RGBA: Hashable, Sendable {
    public var r, g, b, a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// One point of a stroke.
/// Version 1 points have fractional speed, direction, and pressure.
public struct Point: Sendable {
    public var x: Double
    public var y: Double
    public var speed: Double
    public var direction: Double
    public var width: Int
    public var pressure: Double

    public init(x: Double, y: Double, speed: Double, direction: Double, width: Int, pressure: Double) {
        self.x = x
        self.y = y
        self.speed = speed
        self.direction = direction
        self.width = width
        self.pressure = pressure
    }
}

public struct Line: Sendable {
    public var color: PenColor
    public var tool: Pen
    public var points: [Point]
    public var thicknessScale: Double
    public var startingLength: Double
    public var moveId: CrdtId?
    public var colorRGBA: RGBA?

    public init(
        color: PenColor,
        tool: Pen,
        points: [Point],
        thicknessScale: Double,
        startingLength: Double = 0,
        moveId: CrdtId? = nil,
        colorRGBA: RGBA? = nil
    ) {
        self.color = color
        self.tool = tool
        self.points = points
        self.thicknessScale = thicknessScale
        self.startingLength = startingLength
        self.moveId = moveId
        self.colorRGBA = colorRGBA
    }
}

/// Text paragraph style.
public enum ParagraphStyle: Int, Sendable {
    case basic = 0, plain = 1, heading = 2, bold = 3
    case bullet = 4, bullet2 = 5, checkbox = 6, checkboxChecked = 7

    public var name: String {
        switch self {
        case .basic: "BASIC"
        case .plain: "PLAIN"
        case .heading: "HEADING"
        case .bold: "BOLD"
        case .bullet: "BULLET"
        case .bullet2: "BULLET2"
        case .checkbox: "CHECKBOX"
        case .checkboxChecked: "CHECKBOX_CHECKED"
        }
    }
}

/// A text item's value: a string, or a formatting code on an empty string.
public enum TextValue: Equatable, Sendable {
    case string(String)
    case format(UInt32)
}

/// Block of text.
///
/// `items` is a CRDT sequence of strings. Each item's ID refers to its first
/// character; later characters have sequential IDs.
/// `styles` maps character IDs to paragraph styles, which apply to each line.
public struct Text {
    public var items: CrdtSequence<TextValue>
    public var styles: [CrdtId: LwwValue<ParagraphStyle>]
    public var posX: Double
    public var posY: Double
    public var width: Double

    public init(
        items: CrdtSequence<TextValue>,
        styles: [CrdtId: LwwValue<ParagraphStyle>],
        posX: Double,
        posY: Double,
        width: Double
    ) {
        self.items = items
        self.styles = styles
        self.posX = posX
        self.posY = posY
        self.width = width
    }
}

public struct Rectangle: Sendable {
    public var x, y, w, h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Highlighted text.
/// `start` is only present before reMarkable software 3.6.
public struct GlyphRange: Sendable {
    public var start: UInt32?
    public var length: Int
    public var text: String
    public var color: PenColor
    public var rectangles: [Rectangle]
    public var colorRGBA: RGBA?

    public init(
        start: UInt32? = nil,
        length: Int,
        text: String,
        color: PenColor,
        rectangles: [Rectangle],
        colorRGBA: RGBA? = nil
    ) {
        self.start = start
        self.length = length
        self.text = text
        self.color = color
        self.rectangles = rectangles
        self.colorRGBA = colorRGBA
    }
}

// MARK: Scene tree (scene_tree.py)

public let rootId = CrdtId(0, 1)

public final class SceneTree {
    public let root = Group(nodeId: rootId)
    private var nodeIds: [CrdtId: Group]
    public var sceneInfo: SceneInfo?
    public var rootText: Text?

    public init() { nodeIds = [rootId: root] }

    public func contains(_ nodeId: CrdtId) -> Bool { nodeIds[nodeId] != nil }

    public subscript(nodeId: CrdtId) -> Group? { nodeIds[nodeId] }

    public func addNode(_ nodeId: CrdtId, parentId: CrdtId) throws {
        if nodeIds[nodeId] != nil {
            throw RMSceneError.value("Node \(nodeId) already in tree")
        }
        nodeIds[nodeId] = Group(nodeId: nodeId)
    }

    public func addItem(_ item: CrdtSequenceItem<SceneItem?>, parentId: CrdtId) throws {
        guard let parent = nodeIds[parentId] else {
            throw RMSceneError.value("Parent id not known: \(parentId)")
        }
        try parent.children.add(item)
    }

    /// All leaf items (not groups), in order.
    public func walk() throws -> [SceneItem?] {
        try Self.walkItems(.group(root))
    }

    private static func walkItems(_ item: SceneItem?) throws -> [SceneItem?] {
        if case .group(let group)? = item {
            return try group.children.values().flatMap { try walkItems($0) }
        }
        return [item]
    }
}
