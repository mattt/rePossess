import CoreGraphics
import CoreText
import Foundation
import RePossessFormat

/// The tablet's text metrics for one paragraph style, in page pixels.
///
/// Measured on 2026-10-25 from the PDF exports that Mattt's Paper Pure (software 3.29.0.153)
/// made of spike 4's invented test notebooks, at 72/227 points per pixel:
/// body text is 32 px with a line pitch of 45.5 px, Subheading 36 px, Title 64 px in a serif face,
/// and bullets and checkboxes indent 48 px for each level.
/// The vertical model puts each paragraph's first baseline `ascent` below its top,
/// its bottom `descent` below its last baseline, and `gap` above its top.
/// It reproduces every measured baseline-to-baseline distance:
/// body to body 69.5, body to Subheading 89.3, Subheading to body 63.3, and Title to body 70.4.
/// A Title's wrapped lines step 76.0 px, and a Title after another paragraph has a gap of 88.0 px
/// above it (measured on Mattt's own typed pages; Body to Title steps 163.1 px, Title to Title 164.0).
/// The Subheading's wrapped-line pitch is a guess, scaled from the body's, because no sample wraps one.
public struct StyleMetrics: Sendable {
    public var fontName: String
    public var size: CGFloat
    public var ascent: CGFloat
    public var descent: CGFloat
    public var gap: CGFloat
    public var pitch: CGFloat
    public var indent: CGFloat

    public static func metrics(for style: ParagraphStyle) -> StyleMetrics {
        switch style {
        case .heading:
            StyleMetrics(
                fontName: TextFonts.serif,
                size: 64,
                ascent: 63.2,
                descent: 12.8,
                gap: 88,
                pitch: 76,
                indent: 0
            )
        case .bold:
            // pitch: guess, scaled from the body's
            StyleMetrics(
                fontName: TextFonts.sansMedium,
                size: 36,
                ascent: 37.3,
                descent: 5.7,
                gap: 40.1,
                pitch: 51.2,
                indent: 0
            )
        case .bullet, .checkbox, .checkboxChecked:
            StyleMetrics(
                fontName: TextFonts.sans,
                size: 32,
                ascent: 33.6,
                descent: 11.9,
                gap: 24,
                pitch: 45.5,
                indent: 48
            )
        case .bullet2:
            StyleMetrics(
                fontName: TextFonts.sans,
                size: 32,
                ascent: 33.6,
                descent: 11.9,
                gap: 24,
                pitch: 45.5,
                indent: 96
            )
        case .plain, .basic:
            StyleMetrics(
                fontName: TextFonts.sans,
                size: 32,
                ascent: 33.6,
                descent: 11.9,
                gap: 24,
                pitch: 45.5,
                indent: 0
            )
        }
    }
}

/// The Mac fonts that stand in for the tablet's.
///
/// The tablet uses reMarkable Sans and reMarkable Serif, which the Mac does not have.
/// Of the installed fonts, Helvetica Neue was within 1 percent of reMarkable Sans's widths
/// on two measured lines, and Georgia within 1 percent of the serif title.
public enum TextFonts {
    public static let sans = "HelveticaNeue"
    public static let sansMedium = "HelveticaNeue-Medium"
    public static let sansBold = "HelveticaNeue-Bold"
    public static let sansItalic = "HelveticaNeue-Italic"
    public static let serif = "Georgia"
}

/// One laid-out line of typed text.
public struct TextLine {
    /// The line's text, for drawing.
    public var text: NSAttributedString
    /// The plain text of the line.
    public var plain: String
    /// The x of the line's start and the y of its baseline, in page pixels from the top left.
    public var x: CGFloat
    public var baseline: CGFloat
    public var style: ParagraphStyle
    /// Whether this is the first line of its paragraph, which carries the bullet or checkbox.
    public var isFirst: Bool
}

/// Typed text laid out as the tablet lays it out, as closely as rePossess can.
///
/// The layout wraps each paragraph with Core Text in the text block's column,
/// using ``StyleMetrics``.
/// It also gives the baseline of every character's line,
/// which places stroke groups that are anchored to the text.
public struct TextLayout {
    public var lines: [TextLine] = []
    /// The baseline of the line that holds each character, by character ID.
    public var baselines: [CrdtId: CGFloat] = [:]
    /// The top of the text block and the bottom of its last line, in page pixels.
    public var top: CGFloat = 0
    public var bottom: CGFloat = 0

    /// The inset of the text on each side of its block.
    /// The first character of each line starts 4 px inside the block,
    /// and the widest body line in spike 4's exports was 927.2 px of the 936 px block.
    public static let inset: CGFloat = 4

    /// How much wider reMarkable Sans sets text than Helvetica Neue, on average.
    /// On 288 body lines of spike 4's long note, the tablet's lines were 0.65 percent wider
    /// (standard deviation 0.5 percent), so lines wrap as if the column were that much narrower.
    /// With this and the 4 px insets, 663 of the 726 lines on spike 4's 16 exported pages
    /// break where the tablet breaks them; the rest differ by a word near the right edge.
    public static let widthCorrection: CGFloat = 1.0065

    public init() {}

    /// Lays out a page's text.
    ///
    /// - Parameters:
    ///   - text: The page's root text.
    ///   - pageWidth: The page width in pixels; the text block's x is from the page's center.
    public init(text: Text, pageWidth: CGFloat) throws {
        let document = try TextDocument.fromSceneItem(text)
        let left = pageWidth / 2 + CGFloat(text.posX) + Self.inset
        let columnWidth = CGFloat(text.width) - 2 * Self.inset
        top = CGFloat(text.posY)

        var previous: StyleMetrics?
        var lastBaseline: CGFloat = 0
        for paragraph in document.contents {
            let metrics = StyleMetrics.metrics(for: paragraph.style.value)
            var baseline: CGFloat
            if let previous {
                baseline = lastBaseline + previous.descent + metrics.gap + metrics.ascent
            } else {
                baseline = top + metrics.ascent
            }

            let (attributed, ids) = Self.attributed(paragraph, metrics)
            let string = attributed.string
            baselines[paragraph.startId] = baseline
            let wrapWidth = (columnWidth - metrics.indent) / Self.widthCorrection
            for (i, range) in Self.wrap(attributed, width: wrapWidth).enumerated() {
                if i > 0 { baseline += metrics.pitch }
                let lineText = attributed.attributedSubstring(from: NSRange(range, in: string))
                lines.append(
                    TextLine(
                        text: lineText,
                        plain: lineText.string,
                        x: left + metrics.indent,
                        baseline: baseline,
                        style: paragraph.style.value,
                        isFirst: i == 0
                    )
                )
                let first = string.unicodeScalars[..<range.lowerBound].count
                let count = string.unicodeScalars[range].count
                for index in first ..< min(first + count, ids.count) {
                    baselines[ids[index]] = baseline
                }
            }
            lastBaseline = baseline
            previous = metrics
        }
        bottom = lastBaseline + (previous?.descent ?? 0)
    }

    /// The paragraph's text with fonts, and the character ID of each Unicode scalar.
    static func attributed(_ paragraph: Paragraph, _ metrics: StyleMetrics) -> (NSAttributedString, [CrdtId]) {
        let result = NSMutableAttributedString()
        var ids: [CrdtId] = []
        for span in paragraph.contents {
            var fontName = metrics.fontName
            if metrics.fontName == TextFonts.sans {
                if span.properties["font-weight"] == "bold" { fontName = TextFonts.sansBold }
                if span.properties["font-style"] == "italic" { fontName = TextFonts.sansItalic }
            }
            let font = CTFontCreateWithName(fontName as CFString, metrics.size, nil)
            // Each Unicode scalar has one ID; a deleted character is an empty string with an ID, so skip it.
            var text = ""
            for (character, id) in zip(span.s.unicodeScalars, span.i) {
                text.unicodeScalars.append(character)
                ids.append(id)
            }
            let key = NSAttributedString.Key(kCTFontAttributeName as String)
            result.append(NSAttributedString(string: text, attributes: [key: font]))
        }
        return (result, ids)
    }

    /// Breaks text into lines no wider than `width`, at the break points that Core Text suggests.
    static func wrap(_ text: NSAttributedString, width: CGFloat) -> [Range<String.Index>] {
        let string = text.string
        guard !string.isEmpty else { return [string.startIndex ..< string.endIndex] }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var ranges: [Range<String.Index>] = []
        var start = 0
        let utf16Count = (string as NSString).length
        while start < utf16Count {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            let end = start + max(count, 1)
            let from = String.Index(utf16Offset: start, in: string)
            let to = String.Index(utf16Offset: min(end, utf16Count), in: string)
            ranges.append(from ..< to)
            start = end
        }
        return ranges
    }
}
