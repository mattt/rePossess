import CoreGraphics
import Foundation
import ImageIO

/// Scores a recognizer against reference transcriptions.
///
/// The reference folder holds one text file for each strip, in subfolders such as `notebook/`,
/// and the images folder holds the strips with the same names and `.png`,
/// as `captures/handwriting/reference/` and `captures/handwriting/strips/` do.
/// Each strip goes to the recognizer as a page's strip would, scaled to 936 pixels on its longer side.
public enum Evaluation {
    /// One strip with its reference.
    public struct Pair: Sendable, Equatable {
        /// The strip's name, such as `notebook/p01-s01`.
        public var name: String
        public var reference: URL
        public var image: URL

        /// The subfolder, such as `notebook`.
        public var group: String { name.split(separator: "/").dropLast().joined(separator: "/") }
    }

    /// One strip's result, as an output file records it.
    public struct Output: Sendable, Codable {
        /// The image's path from the images folder, such as `notebook/p01-s01.png`.
        public var image: String
        public var text: String
        public var seconds: Double
        public var refused: Bool
        public var error: String?
    }

    /// The scores of a set of strips.
    public struct Score: Sendable {
        public var name: String
        public var strips = 0
        public var counts = Scoring.Counts()
        public var refused = 0
        public var failed = 0
        public var seconds: [Double] = []
    }

    /// The strips that have both a reference and an image, sorted by name.
    public static func pairs(reference: URL, images: URL) throws -> [Pair] {
        let manager = FileManager.default
        guard
            let enumerator = manager.enumerator(
                at: reference,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { throw RecognizerError.configuration("\(reference.path) cannot be read.") }
        var pairs: [Pair] = []
        let base = reference.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in enumerator where url.pathExtension == "txt" {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let name = String(path.dropFirst(base.count + 1).dropLast(4))
            let image = images.appending(path: name + ".png")
            guard manager.fileExists(atPath: image.path) else { continue }
            pairs.append(Pair(name: name, reference: url, image: image))
        }
        return pairs.sorted { $0.name < $1.name }
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RecognizerError.image("\(url.lastPathComponent) is not an image.") }
        return image
    }

    /// Recognizes every strip, one at a time, and returns each output.
    /// A strip whose recognition fails gets an empty text and the error; the rest go on.
    public static func run(
        _ pairs: [Pair],
        recognize: (CGImage) async throws -> StripAnswer,
        progress: (Int, Output) -> Void = { _, _ in }
    ) async -> [Output] {
        var outputs: [Output] = []
        for (i, pair) in pairs.enumerated() {
            let start = ContinuousClock.now
            var output = Output(image: pair.name + ".png", text: "", seconds: 0, refused: false, error: nil)
            do {
                let answer = try await recognize(try loadImage(pair.image))
                output.text = answer.refused ? "" : answer.text
                output.refused = answer.refused
            } catch {
                output.error = "\(error)"
            }
            let elapsed = ContinuousClock.now - start
            output.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            outputs.append(output)
            progress(i + 1, output)
        }
        return outputs
    }

    /// Scores outputs against their references: the whole set, then each subfolder.
    public static func score(_ pairs: [Pair], _ outputs: [Output]) throws -> [Score] {
        var total = Score(name: "all")
        var groups: [String: Score] = [:]
        for (pair, output) in zip(pairs, outputs) {
            let reference = try String(contentsOf: pair.reference, encoding: .utf8)
            let counts = Scoring.score(reference: reference, output: output.text)
            for name in ["all", pair.group] {
                var score = name == "all" ? total : groups[name, default: Score(name: name)]
                score.strips += 1
                score.counts = score.counts + counts
                score.seconds.append(output.seconds)
                if output.refused { score.refused += 1 }
                if output.error != nil { score.failed += 1 }
                if name == "all" { total = score } else { groups[name] = score }
            }
        }
        return [total] + groups.keys.sorted().compactMap { groups[$0] }
    }

    /// The median of the values after the first, which includes a model's load:
    /// the reported seconds for one strip.
    public static func warmMedian(_ seconds: [Double]) -> Double? {
        let warm = seconds.count > 1 ? Array(seconds.dropFirst()) : seconds
        guard !warm.isEmpty else { return nil }
        let sorted = warm.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// A table of numbers only, never text.
    public static func table(_ scores: [Score]) -> String {
        func percent(_ value: Double?) -> String { value.map { String(format: "%5.1f%%", $0 * 100) } ?? "     -" }
        var lines = ["set               strips  words    WER    CER  recall  refused  failed  s/strip  total s"]
        for score in scores {
            let median = warmMedian(score.seconds).map { String(format: "%7.2f", $0) } ?? "      -"
            lines.append(
                score.name.padding(toLength: 16, withPad: " ", startingAt: 0)
                    + String(
                        format: " %7d %6d %@ %@ %@ %8d %7d  %@ %8.1f",
                        score.strips,
                        score.counts.referenceWords,
                        percent(score.counts.wordErrorRate),
                        percent(score.counts.characterErrorRate),
                        " " + percent(score.counts.wordRecall),
                        score.refused,
                        score.failed,
                        median,
                        score.seconds.reduce(0, +)
                    )
            )
        }
        return lines.joined(separator: "\n")
    }
}
