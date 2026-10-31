import Foundation

/// Word and character error rates and word recall.
///
/// Text is normalized before scoring: lowercase, "&" read as "and",
/// the `[[ ]]` marks of uncertain reference words removed,
/// and every character other than a letter, a digit, or white space replaced by a space.
/// The word error rate (WER) and character error rate (CER) are edit distances
/// summed over all strips and divided by the length of the reference.
/// Word recall is the share of reference words, as a multiset, that the output contains,
/// which ignores reading order.
public enum Scoring {
    /// One strip's counts.
    public struct Counts: Sendable, Equatable {
        public var wordEdits = 0
        public var referenceWords = 0
        public var characterEdits = 0
        public var referenceCharacters = 0
        public var wordsFound = 0

        public init() {}

        public static func + (a: Counts, b: Counts) -> Counts {
            var sum = Counts()
            sum.wordEdits = a.wordEdits + b.wordEdits
            sum.referenceWords = a.referenceWords + b.referenceWords
            sum.characterEdits = a.characterEdits + b.characterEdits
            sum.referenceCharacters = a.referenceCharacters + b.referenceCharacters
            sum.wordsFound = a.wordsFound + b.wordsFound
            return sum
        }

        public var wordErrorRate: Double? {
            referenceWords > 0 ? Double(wordEdits) / Double(referenceWords) : nil
        }

        public var characterErrorRate: Double? {
            referenceCharacters > 0 ? Double(characterEdits) / Double(referenceCharacters) : nil
        }

        public var wordRecall: Double? {
            referenceWords > 0 ? Double(wordsFound) / Double(referenceWords) : nil
        }
    }

    /// The text as `score.py`'s `normalize` makes it.
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .replacingOccurrences(of: "&", with: " and ")
        var scalars = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            scalars.append(isWordScalar(scalar) || scalar.properties.isWhitespace ? scalar : " ")
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Python's `\w` without the underscore: letters and numbers.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// The edit distance between two sequences.
    static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        var previous = Array(0 ... b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(b.count + 1)
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// The counts for one output against its reference.
    public static func score(reference: String, output: String) -> Counts {
        let reference = normalize(reference)
        let output = normalize(output)
        let referenceWords = reference.split(separator: " ").map(String.init)
        let outputWords = output.split(separator: " ").map(String.init)
        var counts = Counts()
        counts.wordEdits = distance(referenceWords, outputWords)
        counts.referenceWords = referenceWords.count
        counts.characterEdits = distance(Array(reference.unicodeScalars), Array(output.unicodeScalars))
        counts.referenceCharacters = reference.unicodeScalars.count
        var available: [String: Int] = [:]
        for word in outputWords { available[word, default: 0] += 1 }
        for word in referenceWords where (available[word] ?? 0) > 0 {
            available[word]! -= 1
            counts.wordsFound += 1
        }
        return counts
    }
}
