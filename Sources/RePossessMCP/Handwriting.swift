import Foundation
import MCP
import RePossessLibrary
import RePossessRecognize

/// How the tools reach the recognizer: its configuration, a way to make it, and the client's sampling.
///
/// The configuration is read on every call, so that `repossess recognizer set` and `off`
/// take effect in a running server.
public struct RecognitionContext: Sendable {
    /// The owner's configuration, or `nil` when recognition is off.
    public var configuration: @Sendable () throws -> RecognizerConfiguration?
    /// Makes the recognizer for a configuration; this may load a model.
    public var makeRecognizer: @Sendable (RecognizerConfiguration) async throws -> any StripRecognizer
    /// Whether the connected client declared the `sampling` capability.
    public var clientSamples: @Sendable () async -> Bool
    /// Whether the recognizer can run now, without loading it: a short reason when it cannot.
    public var readiness: @Sendable (RecognizerConfiguration) async -> String?
    /// The longest that one `recognize_pages` call starts new pages for.
    public var budget: Duration

    /// The default for ``budget``, in seconds.
    public static let defaultBudgetSeconds = 45

    public init(
        configuration: @escaping @Sendable () throws -> RecognizerConfiguration?,
        makeRecognizer: @escaping @Sendable (RecognizerConfiguration) async throws -> any StripRecognizer,
        clientSamples: @escaping @Sendable () async -> Bool = { false },
        readiness: @escaping @Sendable (RecognizerConfiguration) async -> String? = { _ in nil },
        budget: Duration = .seconds(defaultBudgetSeconds)
    ) {
        self.configuration = configuration
        self.makeRecognizer = makeRecognizer
        self.clientSamples = clientSamples
        self.readiness = readiness
        self.budget = budget
    }

    /// The live context: `recognizer.json` in the library, the providers through AnyLanguageModel,
    /// and the client's model through `sampler`.
    public static func live(library: Library, sampler: (any ImageSampler)? = nil) -> RecognitionContext {
        RecognitionContext(
            configuration: { try RecognizerConfiguration.activate(in: library) },
            makeRecognizer: { try await RecognizerFactory.make($0, libraryRoot: library.root, sampler: sampler) },
            clientSamples: { await sampler?.isAvailable() ?? false },
            readiness: { configuration in
                switch configuration.provider {
                case .mlx:
                    do {
                        _ = try RecognizerFactory.mlxFolder(configuration, libraryRoot: library.root)
                        return nil
                    } catch {
                        return "\(error)"
                    }
                case .anthropic, .openai, .gemini:
                    return APIKeys.source(for: configuration.provider) == nil
                        ? "No API key for \(configuration.provider.rawValue)." : nil
                case .client:
                    return await sampler?.isAvailable() == true
                        ? nil : "The connected MCP client does not declare the sampling capability."
                case .foundationModels, .ollama:
                    return nil
                }
            }
        )
    }
}

/// Asks the connected client's model to read an image, through MCP sampling,
/// when the client declared the `sampling` capability in `initialize`.
public actor ClientSampling: ImageSampler {
    private var server: Server?
    private var declared = false

    public init() {}

    /// Records the server, so that sampling requests go to its client.
    public func attach(_ server: Server) { self.server = server }

    /// Records whether the client declared sampling.
    public func setDeclared(_ declared: Bool) { self.declared = declared }

    public func isAvailable() -> Bool { declared && server != nil }

    public func complete(prompt: String, png: Data, maxTokens: Int) async throws -> (text: String, model: String) {
        guard let server, declared else {
            throw RecognizerError.unavailable("The connected MCP client does not declare the sampling capability.")
        }
        let result = try await server.requestSampling(
            messages: [
                .user(.multiple([.image(data: png.base64EncodedString(), mimeType: "image/png"), .text(prompt)]))
            ],
            includeContext: Sampling.ContextInclusion.none,
            temperature: 0,
            maxTokens: maxTokens
        )
        let text = result.content.asArray.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }
        return (text.joined(separator: "\n"), result.model)
    }
}

/// What `fetch_document` shows for a page's handwriting.
enum PageHandwriting {
    /// Recognition is off, or the page has no strokes: the marker for the image.
    case notShown
    /// The page was recognized, with this result.
    case recognized(Recognition)
    /// A recognizer is configured, and this page has not been read yet.
    case waiting
}

extension RePossessTools {
    /// The configuration whose text the tools show, or `nil` when they show markers only:
    /// recognition is off, its file cannot be read, or it is the client's model and the client cannot sample.
    func shownConfiguration() async -> RecognizerConfiguration? {
        guard let configuration = try? recognition.configuration() else { return nil }
        if configuration.provider == .client, !(await recognition.clientSamples()) { return nil }
        return configuration
    }

    /// The handwriting state of a page under a configuration.
    func handwriting(_ page: LibraryPage, _ configuration: RecognizerConfiguration?) throws -> PageHandwriting {
        guard let configuration, let hash = page.strokeHash else { return .notShown }
        if let cached = try library.recognition(strokeHash: hash, key: configuration.key) { return .recognized(cached) }
        return .waiting
    }

    /// The line that names who recognized the handwriting, with the provider and the model.
    ///
    /// The caution that recognized text can have errors is in the server's instructions only,
    /// once: when every result repeated it, Claude opened every page image as well.
    static func recognizerLine(_ configuration: RecognizerConfiguration, label: String) -> String {
        "Handwriting on these pages was recognized as text by \(label) "
            + "(provider \(configuration.provider.rawValue), model \(configuration.keyModel))."
    }

    /// The text of a page's handwriting, or a marker that says what to call.
    static func handwritingPart(_ page: LibraryPage, _ state: PageHandwriting, documentID: String) -> String? {
        let n = page.number
        let ink = page.strokeCount > 0
        switch state {
        case .recognized(let r) where r.status == .text:
            return (page.hasText ? "Handwriting on this page, recognized as text:" : "Handwriting, recognized as text:")
                + "\n\n" + r.text
        case .recognized(let r) where r.status == .empty:
            return "[Handwriting or a drawing in which \(r.label) found no words. "
                + "Call fetch_page_image with page_no \(n) to see it.]"
        case .recognized(let r):
            return "[Handwriting that \(r.label) declined to read. Call fetch_page_image with page_no \(n) to see it.]"
        case .waiting:
            return "[\(page.hasText ? "This page also has handwriting or drawings" : "Handwriting or a drawing"), "
                + "not recognized as text yet. Call recognize_pages with id \(documentID) and pages "
                + "{\"start\": \(n), \"end\": \(n)} to read it as text, or fetch_page_image with page_no \(n) to see it.]"
        case .notShown:
            // A notebook page with images and no text or ink: its placeholders name fetch_page_image.
            if !ink, page.sourcePageIndex == nil { return nil }
            if page.needsImage, !page.hasText {
                return ink
                    ? "[Handwriting or a drawing without text. Call fetch_page_image with page_no \(n) to see it.]"
                    : "[A PDF page without a text layer. Call fetch_page_image with page_no \(n) to see it.]"
            }
            if page.needsImage {
                return
                    "[This page also has handwriting or drawings. Call fetch_page_image with page_no \(n) to see them.]"
            }
            return nil
        }
    }

    // MARK: recognize_pages

    func recognizePages(_ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let id = Self.string(arguments, "id") else { throw ToolError("id is required.") }
        let document = try loader.document(id)
        let configuration: RecognizerConfiguration
        do {
            guard let configured = try recognition.configuration() else {
                throw ToolError(
                    "Handwriting recognition is off: the owner has not configured a recognizer "
                        + "(`repossess recognizer set`). Call fetch_page_image or fetch_page_chunks to see the handwriting."
                )
            }
            configuration = configured
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError(
                "The recognizer's configuration could not be read: \(error). Call fetch_page_image instead."
            )
        }
        if configuration.provider == .client, !(await recognition.clientSamples()) {
            throw ToolError(
                "The owner chose the MCP client's model for handwriting, and this client does not declare "
                    + "the sampling capability. Call fetch_page_image or fetch_page_chunks to see the handwriting."
            )
        }
        let all = try library.pages(of: document.id)
        guard !all.isEmpty else { throw ToolError("\(document.name) has no pages that rePossess can read.") }
        let range = arguments["pages"]?.objectValue ?? [:]
        let start = min(max(try Self.integer(range, "start") ?? 1, 1), all.count)
        let end = min(max(try Self.integer(range, "end") ?? all.count, start), all.count)
        let pages = all[(start - 1) ..< end].filter { $0.strokeHash != nil }
        var out = "# \(document.name)\n\nid: \(document.id) · pages \(start) to \(end) of \(all.count)\n"
        guard !pages.isEmpty else {
            return Self.text(out + "\nThese pages have no handwriting or drawings to recognize.\n")
        }
        let waiting = try pages.filter { try handwriting($0, configuration).isWaiting }
        var remaining: [LibraryPage] = []
        var readNow = 0
        var seconds = 0.0
        if !waiting.isEmpty {
            let recognizer: any StripRecognizer
            do {
                recognizer = try await recognition.makeRecognizer(configuration)
            } catch {
                throw ToolError(
                    "The recognizer is not available: \(error) Call fetch_page_image to see the handwriting."
                )
            }
            let reader = HandwritingRecognizer(library: library, configuration: configuration, recognizer: recognizer)
            do {
                let (results, left) = try await reader.recognize(
                    waiting,
                    deadline: ContinuousClock.now + recognition.budget
                )
                readNow = results.count
                seconds = results.reduce(0) { $0 + $1.recognition.seconds }
                remaining = left
            } catch {
                throw ToolError(
                    "Recognition failed: \(error) Pages that were read before the failure are cached. "
                        + "Call fetch_page_image to see the handwriting."
                )
            }
        }
        var label = configuration.label
        var body = ""
        var budget = Self.textBudget
        var stoppedAt: Int?
        let left = Set(remaining.map(\.number))
        for page in pages where !left.contains(page.number) {
            let state = try handwriting(page, configuration)
            if case .recognized(let r) = state { label = r.label }
            let part = Self.handwritingPart(page, state, documentID: document.id) ?? ""
            if body.count > 0, part.count > budget {
                stoppedAt = page.number
                break
            }
            budget -= part.count
            body += "\n--- Page \(page.number) of \(all.count) ---\n\n\(part)\n"
        }
        out += Self.recognizerLine(configuration, label: label) + "\n"
        out += String(
            format: "%d pages were read now, in %.1f seconds; %d came from the cache.\n",
            readNow,
            seconds,
            pages.count - waiting.count
        )
        out += body
        if let next = remaining.first?.number {
            out +=
                "\n--- Stopped before page \(next) to keep this call short. Call recognize_pages with id \(document.id) "
            out += "and pages {\"start\": \(next), \"end\": \(end)} for the rest. ---\n"
        } else if let stoppedAt {
            out += "\n--- The text of page \(stoppedAt) onwards is cached but not shown, to keep this result short. "
            out +=
                "Call fetch_document with id \(document.id) and pages {\"start\": \(stoppedAt), \"end\": \(end)}. ---\n"
        }
        return Self.text(out)
    }

    // MARK: status

    struct RecognizerStatus: Codable {
        /// `off`, `ready`, or `unavailable`.
        let state: String
        let provider: String?
        let model: String?
        let label: String?
        let page_images_go_to: String?
        let pages_with_handwriting: Int?
        let pages_recognized: Int?
        let pages_without_words: Int?
        let pages_refused: Int?
        let pages_waiting: Int?
        let note: String
    }

    func recognizerStatus() async -> RecognizerStatus {
        let configuration: RecognizerConfiguration?
        do {
            configuration = try recognition.configuration()
        } catch {
            return RecognizerStatus(
                state: "unavailable",
                provider: nil,
                model: nil,
                label: nil,
                page_images_go_to: nil,
                pages_with_handwriting: nil,
                pages_recognized: nil,
                pages_without_words: nil,
                pages_refused: nil,
                pages_waiting: nil,
                note: "The configuration could not be read: \(error)"
            )
        }
        guard let configuration else {
            return RecognizerStatus(
                state: "off",
                provider: nil,
                model: nil,
                label: nil,
                page_images_go_to: nil,
                pages_with_handwriting: nil,
                pages_recognized: nil,
                pages_without_words: nil,
                pages_refused: nil,
                pages_waiting: nil,
                note: "Handwriting recognition is off; fetch_page_image and fetch_page_chunks show handwriting."
            )
        }
        let counts = try? library.recognitionCounts(key: configuration.key)
        let problem = await recognition.readiness(configuration)
        return RecognizerStatus(
            state: problem == nil ? "ready" : "unavailable",
            provider: configuration.provider.rawValue,
            model: configuration.keyModel,
            label: configuration.label,
            page_images_go_to: configuration.destination,
            pages_with_handwriting: counts?.pagesWithInk,
            pages_recognized: counts?.text,
            pages_without_words: counts?.empty,
            pages_refused: counts?.refused,
            pages_waiting: counts?.waiting,
            note: problem.map { "\($0) fetch_page_image shows handwriting." }
                ?? "fetch_document includes recognized handwriting; recognize_pages reads pages that wait."
        )
    }
}

extension PageHandwriting {
    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}
