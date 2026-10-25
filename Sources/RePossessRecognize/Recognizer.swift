import AnyLanguageModel
import CoreGraphics
import Foundation
import RePossessFormat
import RePossessLibrary
import RePossessRender

/// One strip's answer from a recognizer.
public struct StripAnswer: Sendable, Equatable {
    public var text: String
    /// Whether the recognizer declined to read the strip, with an error or with a refusal written as text.
    public var refused: Bool

    public init(text: String, refused: Bool = false) {
        self.text = text
        self.refused = refused
    }
}

/// Reads the handwriting in one strip image, already scaled for the recognizer.
public protocol StripRecognizer: Sendable {
    func recognize(_ strip: CGImage) async throws -> StripAnswer
    /// Frees what the recognizer holds in memory, such as a loaded model.
    func unload() async
}

extension StripRecognizer {
    public func unload() async {}
}

/// A recognizer that asks a language model from AnyLanguageModel, one new session for each strip,
/// with spike 5's prompt and greedy decoding where the provider allows it.
public struct LanguageModelStripRecognizer<Model: LanguageModel>: StripRecognizer {
    public let model: Model
    let release: @Sendable () async -> Void

    public init(model: Model, release: @escaping @Sendable () async -> Void = {}) {
        self.model = model
        self.release = release
    }

    /// Greedy sampling, and a temperature of 0 for the providers that read only the temperature.
    public static var options: GenerationOptions {
        GenerationOptions(
            sampling: .greedy,
            temperature: 0,
            maximumResponseTokens: RecognitionPrompt.maximumResponseTokens
        )
    }

    public func recognize(_ strip: CGImage) async throws -> StripAnswer {
        let session = LanguageModelSession(model: model)
        do {
            let response = try await session.respond(options: Self.options) {
                RecognitionPrompt.text
                Attachment(strip)
            }
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return StripAnswer(text: text, refused: RefusalDetector.isRefusal(text))
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return StripAnswer(text: "", refused: true)
            default: throw error
            }
        }
    }

    public func unload() async { await release() }
}

/// Asks the connected MCP client's model to read an image, through MCP sampling.
public protocol ImageSampler: Sendable {
    /// Whether the connected client declared the `sampling` capability.
    func isAvailable() async -> Bool
    /// Sends the prompt and a PNG image, and returns the text and the name of the model that answered.
    func complete(prompt: String, png: Data, maxTokens: Int) async throws -> (text: String, model: String)
}

/// A recognizer that reads strips through the MCP client's model.
public struct ClientStripRecognizer: StripRecognizer {
    let sampler: any ImageSampler

    public init(sampler: any ImageSampler) { self.sampler = sampler }

    public func recognize(_ strip: CGImage) async throws -> StripAnswer {
        let (text, _) = try await sampler.complete(
            prompt: RecognitionPrompt.text,
            png: try StripCutter.png(strip),
            maxTokens: RecognitionPrompt.maximumResponseTokens
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return StripAnswer(text: trimmed, refused: RefusalDetector.isRefusal(trimmed))
    }
}

/// Makes the recognizer that a configuration names.
public enum RecognizerFactory {
    /// The recognizer for a configuration.
    ///
    /// - Throws: ``RecognizerError/modelMissing(_:)`` when the MLX model is not on this Mac,
    ///   ``RecognizerError/apiKeyMissing(_:)`` when a cloud provider has no key,
    ///   and ``RecognizerError/unavailable(_:)`` when the on-device model or the client cannot be used.
    public static func make(
        _ configuration: RecognizerConfiguration,
        libraryRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keys: any APIKeyStore = SystemAPIKeychain(),
        sampler: (any ImageSampler)? = nil
    ) async throws -> any StripRecognizer {
        switch configuration.provider {
        case .mlx:
            let folder = try mlxFolder(configuration, libraryRoot: libraryRoot, environment: environment)
            // Nothing in this path should reach the network; tell Hugging Face's libraries so too.
            setenv("HF_HUB_OFFLINE", "1", 1)
            let model = MLXLanguageModel(modelId: PinnedModel.qwen3VL8B.repository, directory: folder)
            return LanguageModelStripRecognizer(model: model, release: { await model.removeFromCache() })
        case .foundationModels:
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            guard case .available = model.availability else {
                throw RecognizerError.unavailable(
                    "The on-device Foundation Models model is not available on this Mac (\(model.availability))."
                )
            }
            return LanguageModelStripRecognizer(model: model)
        case .anthropic:
            let key = try APIKeys.key(for: .anthropic, environment: environment, store: keys)
            return LanguageModelStripRecognizer(
                model: AnthropicLanguageModel(
                    baseURL: configuration.effectiveBaseURL!,
                    apiKey: key,
                    model: configuration.model ?? ""
                )
            )
        case .openai:
            let key = try APIKeys.key(for: .openai, environment: environment, store: keys)
            return LanguageModelStripRecognizer(
                model: OpenAILanguageModel(
                    baseURL: configuration.effectiveBaseURL!,
                    apiKey: key,
                    model: configuration.model ?? ""
                )
            )
        case .gemini:
            let key = try APIKeys.key(for: .gemini, environment: environment, store: keys)
            return LanguageModelStripRecognizer(
                model: GeminiLanguageModel(
                    baseURL: configuration.effectiveBaseURL!,
                    apiKey: key,
                    model: configuration.model ?? ""
                )
            )
        case .ollama:
            return LanguageModelStripRecognizer(
                model: OllamaLanguageModel(baseURL: configuration.effectiveBaseURL!, model: configuration.model ?? "")
            )
        case .client:
            guard let sampler, await sampler.isAvailable() else {
                throw RecognizerError.unavailable(
                    "The connected MCP client does not declare the sampling capability, so it cannot read handwriting "
                        + "for rePossess; use fetch_page_image or fetch_page_chunks to see the page."
                )
            }
            return ClientStripRecognizer(sampler: sampler)
        }
    }

    /// The folder of the MLX model: the configured path, or the pinned model's copy.
    public static func mlxFolder(
        _ configuration: RecognizerConfiguration,
        libraryRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let path = configuration.modelPath {
            let url = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: url.appending(path: "config.json").path) else {
                throw RecognizerError.modelMissing("\(url.path) has no MLX model (no config.json).")
            }
            return url
        }
        let store = ModelStore(libraryRoot: libraryRoot, environment: environment)
        guard let folder = store.locate() else {
            let gigabytes = String(format: "%.1f", Double(store.model.totalBytes) / 1e9)
            throw RecognizerError.modelMissing(
                "The recognizer's model, \(store.model.repository), is not on this Mac. "
                    + "Run `repossess model download` to download it (\(gigabytes) GB from Hugging Face)."
            )
        }
        return folder
    }
}

/// The outcome of recognizing one page.
public struct PageRecognitionResult: Sendable {
    public var documentID: String
    public var pageNo: Int
    public var recognition: Recognition
    /// Whether the text came from the cache rather than from the recognizer.
    public var cached: Bool
}

/// Recognizes pages of handwriting, caches each result, and indexes its text.
///
/// Each page renders with only its strokes, is cut into strips at blank rows (``StripCutter``),
/// and each strip, scaled to 936 pixels on its longer side, goes to the recognizer.
/// The strips' texts join with newlines, in order.
/// When any strip is refused, the page is unread: its result is `refused` and has no text.
/// Results are cached by the hash of the page's strokes and the configuration's key,
/// so a page is read again only when its strokes or the recognizer change.
public struct HandwritingRecognizer: Sendable {
    public let library: Library
    public let configuration: RecognizerConfiguration
    let recognizer: any StripRecognizer

    public init(library: Library, configuration: RecognizerConfiguration, recognizer: any StripRecognizer) {
        self.library = library
        self.configuration = configuration
        self.recognizer = recognizer
    }

    public var key: RecognitionKey { configuration.key }

    /// Reads one strip image of any size, scaled first as for a page.
    public func recognize(strip image: CGImage) async throws -> StripAnswer {
        try await recognizer.recognize(try StripCutter.scaled(image))
    }

    /// The scene of a page as the recognizer reads it: only its strokes, on a page of the right size.
    public static func scene(_ library: Library, _ page: LibraryPage) throws -> PageScene {
        let folder = try library.folder(for: page.documentID)
        let bytes = try folder.pageBytes(page.pageID)
        var pdfPage: CGPDFPage?
        if let index = page.sourcePageIndex, folder.hasPDF, let pdf = CGPDFDocument(folder.pdfURL as CFURL) {
            // The PDF page sets the page's width, which places the strokes; it is not drawn.
            pdfPage = pdf.page(at: index + 1)
        }
        return PageScene(pageBytes: bytes, pdfPage: pdfPage).strokesOnly()
    }

    /// Recognizes a page, or returns its cached result.
    /// - Parameter again: Recognize the page even when a result is cached, such as after a refusal.
    public func recognize(_ page: LibraryPage, again: Bool = false) async throws -> PageRecognitionResult {
        guard let hash = page.strokeHash else {
            throw RecognizerError.image("Page \(page.number) has no handwriting.")
        }
        if !again, let cached = try library.recognition(strokeHash: hash, key: key) {
            return PageRecognitionResult(
                documentID: page.documentID,
                pageNo: page.number,
                recognition: cached,
                cached: true
            )
        }
        let start = ContinuousClock.now
        let strips = try StripCutter.strips(try Self.scene(library, page))
        var texts: [String] = []
        var refused = false
        for strip in strips {
            let answer = try await recognizer.recognize(try StripCutter.scaled(strip.image))
            if answer.refused {
                refused = true
                break
            }
            if !answer.text.isEmpty { texts.append(answer.text) }
        }
        let elapsed = ContinuousClock.now - start
        let text = texts.joined(separator: "\n")
        let recognition = Recognition(
            key: key,
            strokeHash: hash,
            status: refused ? .refused : (text.isEmpty ? .empty : .text),
            text: text,
            label: configuration.label,
            strips: strips.count,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
        try library.storeRecognition(recognition)
        return PageRecognitionResult(
            documentID: page.documentID,
            pageNo: page.number,
            recognition: recognition,
            cached: false
        )
    }

    /// Recognizes pages in order until they are done or the deadline passes,
    /// holding the library's recognition lock, and frees the model afterwards.
    ///
    /// A page that has started finishes, even after the deadline.
    /// - Returns: The results, and the pages that were left for later.
    public func recognize(
        _ pages: [LibraryPage],
        again: Bool = false,
        deadline: ContinuousClock.Instant? = nil,
        progress: @Sendable (PageRecognitionResult) -> Void = { _ in }
    ) async throws -> (results: [PageRecognitionResult], remaining: [LibraryPage]) {
        try await RecognitionLock.with(library.root) {
            var results: [PageRecognitionResult] = []
            var remaining = pages[...]
            defer { _ = remaining }
            do {
                while let page = remaining.first {
                    if let deadline, ContinuousClock.now >= deadline { break }
                    let result = try await recognize(page, again: again)
                    results.append(result)
                    progress(result)
                    remaining = remaining.dropFirst()
                }
            } catch {
                await recognizer.unload()
                throw error
            }
            await recognizer.unload()
            return (results, Array(remaining))
        }
    }
}

/// Keeps two processes from recognizing at once, so that two copies of a model never load together.
enum RecognitionLock {
    static func with<T>(_ root: URL, _ body: () async throws -> T) async throws -> T {
        let path = root.appending(path: "recognize.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw RecognizerError.unavailable(
                "Another rePossess process is recognizing handwriting in this library; try again when it finishes."
            )
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }
}
