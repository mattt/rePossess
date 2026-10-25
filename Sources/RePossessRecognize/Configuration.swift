import Foundation
import RePossessLibrary

/// The recognizers that rePossess can use, through AnyLanguageModel or through the MCP client.
public enum RecognizerProvider: String, Sendable, Codable, CaseIterable {
    /// Qwen3-VL 8B 4-bit through MLX, on this Mac: the pinned model of spike 5.
    case mlx
    /// The Foundation Models on-device model, with permissive guardrails, on this Mac.
    case foundationModels = "foundation-models"
    /// Anthropic's API.
    case anthropic
    /// OpenAI's API, or another server with the same Chat Completions API.
    case openai
    /// Google's Gemini API.
    case gemini
    /// An Ollama server, on this Mac by default.
    case ollama
    /// The connected MCP client's model, through MCP sampling,
    /// when the client declares the `sampling` capability.
    case client

    /// Whether the provider needs an API key.
    public var needsAPIKey: Bool { self == .anthropic || self == .openai || self == .gemini }

    /// Whether the provider needs `--model`, because rePossess names no default for it.
    public var needsModel: Bool { needsAPIKey || self == .ollama }

    /// The environment variables that hold the provider's API key, in the order read.
    public var apiKeyVariables: [String] {
        switch self {
        case .anthropic: ["ANTHROPIC_API_KEY"]
        case .openai: ["OPENAI_API_KEY"]
        case .gemini: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        default: []
        }
    }

    /// The default API address.
    var defaultBaseURL: URL? {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com")
        case .openai: URL(string: "https://api.openai.com/v1/")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com")
        case .ollama: URL(string: "http://localhost:11434")
        default: nil
        }
    }

    /// A name for the company or program behind the provider.
    public var owner: String {
        switch self {
        case .mlx: "MLX"
        case .foundationModels: "Apple's Foundation Models"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Google"
        case .ollama: "Ollama"
        case .client: "the MCP client"
        }
    }
}

/// An error in the recognizer's configuration, its model, or its input.
public enum RecognizerError: Error, CustomStringConvertible, Equatable {
    case configuration(String)
    case modelMissing(String)
    case apiKeyMissing(String)
    case unavailable(String)
    case image(String)
    case download(String)

    public var description: String {
        switch self {
        case .configuration(let message), .modelMissing(let message), .apiKeyMissing(let message),
            .unavailable(let message), .image(let message), .download(let message):
            message
        }
    }
}

/// The owner's choice of recognizer, kept in `recognizer.json` in the library folder.
///
/// Recognition is off when the file does not exist, which is the default.
/// The file never holds an API key.
public struct RecognizerConfiguration: Sendable, Equatable, Codable {
    public var provider: RecognizerProvider
    /// The model's name for the provider; for `mlx`, the pinned repository unless `modelPath` is set.
    public var model: String?
    /// The API's address, for `openai` and `ollama`.
    public var baseURL: URL?
    /// A local folder with an MLX model, for `mlx`, in place of the pinned model.
    public var modelPath: String?
    /// Where page images go, in words. rePossess writes it from the provider and the address,
    /// so that anyone who reads the file sees it.
    public var pageImagesGoTo: String
    /// When the owner set the configuration.
    public var configured: Date?

    enum CodingKeys: String, CodingKey {
        case provider, model
        case baseURL = "base_url"
        case modelPath = "model_path"
        case pageImagesGoTo = "page_images_go_to"
        case configured
    }

    /// The configuration file's name in the library folder.
    public static let fileName = "recognizer.json"

    public init(
        provider: RecognizerProvider,
        model: String? = nil,
        baseURL: URL? = nil,
        modelPath: String? = nil,
        configured: Date? = Date()
    ) throws {
        self.provider = provider
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.modelPath = modelPath
        self.configured = configured
        self.pageImagesGoTo = ""
        if provider.needsModel, (self.model ?? "").isEmpty {
            throw RecognizerError.configuration(
                "\(provider.rawValue) needs --model with the provider's name for a model that reads images."
            )
        }
        if provider == .mlx, model != nil, modelPath == nil {
            throw RecognizerError.configuration(
                "mlx uses the pinned model \(PinnedModel.qwen3VL8B.repository); "
                    + "give --model-path with a local folder to use another MLX model."
            )
        }
        if let baseURL, baseURL.scheme != "https", !(baseURL.scheme == "http" && Self.isLocal(baseURL)) {
            throw RecognizerError.configuration("The base URL must be https, or http on this Mac.")
        }
        pageImagesGoTo = destination
    }

    /// Whether a URL names this Mac.
    static func isLocal(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host()?.lowercased() ?? "")
    }

    /// The API address in use.
    public var effectiveBaseURL: URL? { baseURL ?? provider.defaultBaseURL }

    /// The host that receives page images, or `nil` when recognition stays on this Mac.
    public var receivingHost: String? {
        switch provider {
        case .mlx, .foundationModels: return nil
        case .client: return "the MCP client"
        case .ollama:
            guard let url = effectiveBaseURL, !Self.isLocal(url) else { return nil }
            return url.host()
        case .anthropic, .openai, .gemini:
            return effectiveBaseURL?.host()
        }
    }

    /// Where page images go, in words.
    public var destination: String {
        switch provider {
        case .mlx, .foundationModels:
            return "nowhere: recognition runs on this Mac"
        case .client:
            return "the connected MCP client, which sends them to its own model"
        case .ollama where receivingHost == nil:
            return "the Ollama server on this Mac"
        default:
            return "\(receivingHost ?? "unknown host") (\(provider.owner)), which reads each page with ink"
        }
    }

    /// Whether the owner must say that page images may leave the Mac (`--send-page-images`).
    public var sendsPageImages: Bool { receivingHost != nil }

    /// The model as the cache key names it.
    public var keyModel: String {
        switch provider {
        case .mlx:
            if let modelPath { return "path:" + (modelPath as NSString).lastPathComponent }
            return PinnedModel.qwen3VL8B.repository + "@" + PinnedModel.qwen3VL8B.revision
        case .foundationModels: return "SystemLanguageModel.default, permissive guardrails"
        case .client: return "sampling"
        default: return model ?? ""
        }
    }

    /// The cache key for this configuration.
    public var key: RecognitionKey {
        RecognitionKey(provider: provider.rawValue, model: keyModel, promptVersion: RecognitionPrompt.version)
    }

    /// A short name for tool results, such as "Qwen3-VL 8B 4-bit (MLX, on this Mac)".
    public var label: String {
        switch provider {
        case .mlx:
            if let modelPath { return "\((modelPath as NSString).lastPathComponent) (MLX, on this Mac)" }
            return "Qwen3-VL 8B 4-bit (MLX, on this Mac)"
        case .foundationModels: return "Apple's on-device Foundation Models model (on this Mac)"
        case .client: return "the MCP client's model"
        default: return "\(model ?? "") (\(provider.owner))"
        }
    }

    // MARK: The file

    /// The configuration file in a library folder.
    public static func url(in libraryRoot: URL) -> URL {
        libraryRoot.appending(path: fileName)
    }

    /// The configuration in a library folder, or `nil` when recognition is off.
    public static func load(from libraryRoot: URL) throws -> RecognizerConfiguration? {
        let url = url(in: libraryRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var configuration = try decoder.decode(RecognizerConfiguration.self, from: Data(contentsOf: url))
            // The file's sentence is for people; the provider and the address decide.
            configuration.pageImagesGoTo = configuration.destination
            return configuration
        } catch {
            throw RecognizerError.configuration("\(url.path) could not be read: \(error)")
        }
    }

    /// Writes the configuration to a library folder.
    public func save(to libraryRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url(in: libraryRoot), options: .atomic)
    }

    /// Removes the configuration from a library folder, which turns recognition off.
    /// - Returns: Whether there was a configuration.
    @discardableResult
    public static func remove(from libraryRoot: URL) throws -> Bool {
        let url = url(in: libraryRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }
}

extension RecognizerConfiguration {
    /// Reads the library's configuration and makes the library's active key match it,
    /// so that `fetch_document` and search use the configured recognizer's text.
    /// - Returns: The configuration, or `nil` when recognition is off.
    @discardableResult
    public static func activate(in library: Library) throws -> RecognizerConfiguration? {
        let configuration = try load(from: library.root)
        try library.setActiveRecognitionKey(configuration?.key)
        return configuration
    }
}
