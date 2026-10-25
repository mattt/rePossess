import Foundation

/// The prompt from spike 5, and the version that the cache keys name.
public enum RecognitionPrompt {
    /// The prompt that spike 5 sent with each strip (`mlx_ocr.py` and `hw-fm`).
    public static let text = """
        Transcribe the handwritten text in this image exactly as written, line by line, \
        from top to bottom. Keep the writer's words and spelling. \
        Write a dash at the start of a line that starts with a dash. \
        Output only the transcription, with no commentary.
        """

    /// The version of the prompt, the strip rule, and the image scale together.
    /// Change it when any of them changes, so that cached text from the old rules is not shown.
    public static let version = "spike5-1872-936"

    /// The most tokens that one strip's answer may take, as in spike 5.
    public static let maximumResponseTokens = 1024
}

/// Finds refusals that a model returns as text instead of an error.
///
/// Foundation Models with permissive guardrails "may still sometimes refuse",
/// and then it writes the refusal as its answer (spike 5).
/// A refusal is short and starts with an apology or a statement that the model cannot help;
/// handwriting that happens to contain "sorry" or "cannot" is longer or starts otherwise.
public enum RefusalDetector {
    /// The openings of a refusal, lowercased, with straight apostrophes.
    static let openings = [
        "i'm sorry", "i am sorry", "sorry, ", "sorry but", "i apologize", "i apologise",
        "i can't", "i cannot", "i can not", "i'm unable", "i am unable", "i'm not able", "i am not able",
        "unfortunately, i", "as an ai", "i won't", "i will not",
    ]

    /// Words that a refusal uses about the task.
    static let subjects = [
        "transcri", "image", "assist", "help", "provide", "request", "content", "handwrit", "read",
        "process", "comply",
    ]

    /// Whether the text reads as a refusal.
    public static func isRefusal(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 400 else { return false }
        guard openings.contains(where: normalized.hasPrefix) else { return false }
        let firstSentence = normalized.prefix { $0 != "." && $0 != "\n" }
        return subjects.contains { firstSentence.contains($0) }
    }
}
