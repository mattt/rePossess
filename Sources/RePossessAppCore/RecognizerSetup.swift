import Foundation
import RePossessRecognize

/// The fields of the recognizer's setup, before the owner saves them.
///
/// The settings edit a draft in a sheet; the saved configuration stays active
/// until the owner confirms the draft. The draft states each problem as guidance for its field,
/// in place of the command's messages, which name command-line options.
public struct RecognizerDraft: Equatable, Sendable {
    public var provider: RecognizerProvider
    /// The provider's name for a model, for the providers that need one.
    public var model: String
    /// The API's address, for OpenAI and Ollama; empty for the default.
    public var address: String
    /// A local MLX model from `repossess recognizer set mlx --model-path`, which the draft keeps.
    public var modelPath: String?

    public init(provider: RecognizerProvider = .mlx, model: String = "", address: String = "") {
        self.provider = provider
        self.model = model
        self.address = address
    }

    /// A draft with a saved configuration's values.
    public init(_ configuration: RecognizerConfiguration) {
        provider = configuration.provider
        model = configuration.provider.needsModel ? configuration.model ?? "" : ""
        address = configuration.baseURL?.absoluteString ?? ""
        modelPath = configuration.modelPath
    }

    /// Whether the provider needs a model's name.
    public var showsModel: Bool { provider.needsModel }

    /// Whether the provider takes an address.
    public var showsAddress: Bool { provider == .openai || provider == .ollama }

    /// The address that an empty field means, such as `https://api.openai.com/v1/`.
    public var defaultAddress: String? { provider.defaultBaseURL?.absoluteString }

    /// What is wrong with the model field, or `nil` when it is right or not needed.
    public var modelProblem: String? {
        guard showsModel, model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Enter the provider's name for a model that reads images."
    }

    /// What is wrong with the address field, or `nil` when it is right, empty, or not needed.
    public var addressProblem: String? {
        guard showsAddress else { return nil }
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), url.host() != nil else {
            return "Enter a full address that starts with https://."
        }
        if scheme == "https" || (scheme == "http" && RecognizerConfiguration.isLocal(url)) { return nil }
        return "Use an https address, or an http address on this Mac, such as http://localhost:11434."
    }

    /// The configuration that the draft describes, or `nil` while a field has a problem.
    public var configuration: RecognizerConfiguration? {
        guard modelProblem == nil, addressProblem == nil else { return nil }
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? RecognizerConfiguration(
            provider: provider,
            model: showsModel ? model : nil,
            baseURL: showsAddress && !text.isEmpty ? URL(string: text) : nil,
            modelPath: provider == .mlx ? modelPath : nil
        )
    }

    /// A short name for a provider, for the picker.
    public static func name(_ provider: RecognizerProvider) -> String {
        switch provider {
        case .mlx: "Qwen3-VL on This Mac"
        case .foundationModels: "Apple Foundation Models on This Mac"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI or Compatible Server"
        case .gemini: "Google Gemini"
        case .ollama: "Ollama"
        case .client: "MCP Client's Model"
        }
    }

    /// What a provider does and needs, in one or two sentences, for the text below the picker.
    public static func explanation(_ provider: RecognizerProvider) -> String {
        switch provider {
        case .mlx:
            "Reads handwriting on this Mac with Qwen3-VL 8B through MLX. "
                + "It needs a 5.8 GB model, which you download separately."
        case .foundationModels:
            "Reads handwriting on this Mac with Apple's on-device model. "
                + "It needs no download, and it was less accurate than Qwen3-VL in rePossess's tests."
        case .anthropic:
            "Sends an image of each page with handwriting to Anthropic's API. It needs an API key and a model."
        case .openai:
            "Sends an image of each page with handwriting to OpenAI's API, "
                + "or to another server with the same API. It needs an API key and a model."
        case .gemini:
            "Sends an image of each page with handwriting to Google's Gemini API. It needs an API key and a model."
        case .ollama:
            "Sends an image of each page with handwriting to an Ollama server, on this Mac unless you give "
                + "another address. It needs a model."
        case .client:
            "Asks the connected AI client's model, only when the client calls recognize_pages. "
                + "The app does not recognize handwriting in the background with it."
        }
    }
}

/// Whether recognition can run with the saved configuration, in one state for the settings and the menu.
public enum RecognizerReadiness: Equatable, Sendable {
    /// No recognizer is configured.
    case off
    /// The recognizer can run.
    case ready
    /// The recognizer is the pinned MLX model, which is not on this Mac.
    case modelRequired
    /// The provider needs an API key, and none is in the environment or the login keychain.
    case apiKeyRequired
    /// The MCP client's model, which only a client's `recognize_pages` can use.
    case clientOnly
    /// The configuration file could not be read.
    case unreadable(String)

    /// The state of a configuration.
    /// - Parameters:
    ///   - modelPresent: Whether the pinned model is on this Mac.
    ///   - apiKeySource: Where the provider's API key would come from, or `nil` when there is none.
    public static func of(
        _ configuration: RecognizerConfiguration?,
        error: String? = nil,
        modelPresent: Bool,
        apiKeySource: String?
    ) -> Self {
        if let error { return .unreadable(error) }
        guard let configuration else { return .off }
        if configuration.provider == .client { return .clientOnly }
        if configuration.provider == .mlx, configuration.modelPath == nil, !modelPresent { return .modelRequired }
        if configuration.provider.needsAPIKey, apiKeySource == nil { return .apiKeyRequired }
        return .ready
    }

    /// A short title, such as "Ready" or "Model Required".
    public var title: String {
        switch self {
        case .off: "Off"
        case .ready: "Ready"
        case .modelRequired: "Model Required"
        case .apiKeyRequired: "API Key Required"
        case .clientOnly: "Ready When a Client Asks"
        case .unreadable: "Configuration Error"
        }
    }

    /// What the state means and what to do, in one sentence.
    public var detail: String {
        switch self {
        case .off: "AI clients read handwriting from the page images."
        case .ready: "rePossess reads new handwriting after each refresh."
        case .modelRequired: "Download the model below; until then, rePossess reads no handwriting."
        case .apiKeyRequired: "Save an API key below; until then, rePossess reads no handwriting."
        case .clientOnly: "Handwriting is read only when an MCP client that offers sampling calls recognize_pages."
        case .unreadable(let message): message
        }
    }

    /// An SF Symbol for the state.
    public var symbol: String {
        switch self {
        case .off: "circle.slash"
        case .ready, .clientOnly: "checkmark.circle"
        case .modelRequired: "arrow.down.circle"
        case .apiKeyRequired: "key"
        case .unreadable: "exclamationmark.triangle"
        }
    }

    /// Whether the state needs the owner to act.
    public var needsAction: Bool {
        switch self {
        case .modelRequired, .apiKeyRequired, .unreadable: true
        case .off, .ready, .clientOnly: false
        }
    }
}

/// The model download's state, for its progress bar and its messages.
public enum ModelDownloadState: Equatable, Sendable {
    /// No download has run since the app started.
    case idle
    /// The download runs, with the bytes on the Mac and the model's total.
    case running(done: Int64, total: Int64)
    /// The owner stopped it; the files and the partial file stay, and the next download continues.
    case stopped(done: Int64, total: Int64)
    /// It failed with a message.
    case failed(String)
    /// Every file is on the Mac and matches its SHA-256.
    case finished

    /// Whether the download runs.
    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The bytes on the Mac and the total, while it runs or after it stopped.
    public var bytes: (done: Int64, total: Int64)? {
        switch self {
        case .running(let done, let total), .stopped(let done, let total): (done, total)
        default: nil
        }
    }

    /// A size in the units that the settings use, such as "1.2 GB".
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    /// The progress in words, such as "1.2 GB of 5.8 GB".
    public var progressText: String? {
        bytes.map { "\(Self.size($0.done)) of \(Self.size($0.total))" }
    }
}
