import Foundation
import RePossessLibrary
import RePossessMCP
import RePossessRecognize

/// `repossess recognizer ...`: show, set, or turn off the recognizer, keep an API key, and evaluate.
func recognizerCommand(_ arguments: Arguments) async throws {
    let root = libraryRoot(arguments)
    guard let action = arguments.positional.first else {
        throw UsageError("recognizer needs show, set, off, key, or eval")
    }
    switch action {
    case "show":
        let library = try Library(root: root)
        guard let configuration = try RecognizerConfiguration.activate(in: library) else {
            print("Recognizer: off. fetch_document marks handwriting for the AI client to read from the page images.")
            print("Turn it on with `repossess recognizer set mlx` (or foundation-models, anthropic, openai, gemini,")
            print("ollama, or client).")
            return
        }
        print(describe(configuration, library: library))

    case "set":
        guard arguments.positional.count == 2, let provider = RecognizerProvider(rawValue: arguments.positional[1])
        else {
            let names = RecognizerProvider.allCases.map(\.rawValue).joined(separator: ", ")
            throw UsageError("recognizer set needs one provider: \(names)")
        }
        let configuration = try RecognizerConfiguration(
            provider: provider,
            model: arguments.options["--model"],
            baseURL: try arguments.options["--base-url"].map { value in
                guard let url = URL(string: value), url.host() != nil else {
                    throw UsageError("--base-url must be a URL")
                }
                return url
            },
            modelPath: arguments.options["--model-path"]
        )
        if configuration.sendsPageImages, !arguments.flags.contains("--send-page-images") {
            throw UsageError(
                """
                With \(provider.rawValue), rePossess sends an image of each page with handwriting to \
                \(configuration.destination).
                Run the command again with --send-page-images to allow it, or choose mlx or foundation-models, \
                which read pages on this Mac.
                """
            )
        }
        let library = try Library(root: root)
        try configuration.save(to: root)
        try library.setActiveRecognitionKey(configuration.key)
        print(describe(configuration, library: library))

    case "off":
        let library = try Library(root: root)
        let removed = try RecognizerConfiguration.remove(from: root)
        try library.setActiveRecognitionKey(nil)
        print(
            removed
                ? "Recognizer: off. Recognized text stays in the cache and returns if you turn the same recognizer on."
                : "Recognizer: already off."
        )

    case "key":
        guard arguments.positional.count == 2, let provider = RecognizerProvider(rawValue: arguments.positional[1]),
            provider.needsAPIKey
        else { throw UsageError("recognizer key needs anthropic, openai, or gemini") }
        printError("Paste the \(provider.rawValue) API key and press Return; it is kept in the login keychain:")
        guard let key = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            throw UsageError("no key on standard input")
        }
        try SystemAPIKeychain().save(key, provider: provider.rawValue)
        print("Kept the \(provider.rawValue) API key in the login keychain under \"\(APIKeys.service)\".")

    case "eval":
        try await evaluate(arguments, root: root)

    default:
        throw UsageError("unknown recognizer command \(action)")
    }
}

/// The configuration in words, with where page images go and how many pages it has read.
func describe(_ configuration: RecognizerConfiguration, library: Library) -> String {
    var lines = [
        "Recognizer: \(configuration.provider.rawValue)",
        "Model: \(configuration.label)",
        "Page images go to: \(configuration.destination)",
    ]
    if let url = configuration.effectiveBaseURL, configuration.provider != .mlx {
        lines.append("Address: \(url.absoluteString)")
    }
    switch configuration.provider {
    case .mlx:
        if let folder = try? RecognizerFactory.mlxFolder(configuration, libraryRoot: library.root) {
            lines.append("Model folder: \(folder.path)")
        } else {
            lines.append("Model folder: none. Run `repossess model download` before recognizing.")
        }
    case .anthropic, .openai, .gemini:
        let source = APIKeys.source(for: configuration.provider)
        lines.append(
            "API key: \(source ?? "none; set \(configuration.provider.apiKeyVariables[0]) or run `repossess recognizer key`")"
        )
    case .client:
        lines.append("Works only with MCP clients that declare the sampling capability; Claude Code 2.1.310 does not.")
    default:
        break
    }
    if let counts = try? library.recognitionCounts(key: configuration.key) {
        lines.append(
            "Pages with handwriting: \(counts.pagesWithInk); read: \(counts.text + counts.empty) "
                + "(\(counts.empty) without words), refused: \(counts.refused), waiting: \(counts.waiting)"
        )
    }
    lines.append("Configuration: \(RecognizerConfiguration.url(in: library.root).path)")
    return lines.joined(separator: "\n")
}

/// `repossess recognizer eval <reference-dir>`: scores a recognizer against reference transcriptions.
func evaluate(_ arguments: Arguments, root: URL) async throws {
    guard arguments.positional.count == 2 else {
        throw UsageError(
            "recognizer eval needs a folder of reference transcriptions, one .txt file for each strip image"
        )
    }
    let reference = URL(
        filePath: (arguments.positional[1] as NSString).expandingTildeInPath,
        directoryHint: .isDirectory
    )
    let images =
        arguments.options["--images"].map {
            URL(filePath: ($0 as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        ?? reference.deletingLastPathComponent().appending(path: "strips", directoryHint: .isDirectory)
    let configuration: RecognizerConfiguration
    if let name = arguments.options["--provider"] {
        guard let provider = RecognizerProvider(rawValue: name) else { throw UsageError("unknown provider \(name)") }
        configuration = try RecognizerConfiguration(
            provider: provider,
            model: arguments.options["--model"],
            baseURL: arguments.options["--base-url"].flatMap(URL.init(string:)),
            modelPath: arguments.options["--model-path"]
        )
        if configuration.sendsPageImages, !arguments.flags.contains("--send-page-images") {
            throw UsageError("With \(name), the strips go to \(configuration.destination); add --send-page-images.")
        }
    } else {
        guard let configured = try RecognizerConfiguration.load(from: root) else {
            throw UsageError("no recognizer is configured; give --provider, or run `repossess recognizer set`")
        }
        configuration = configured
    }
    var pairs = try Evaluation.pairs(reference: reference, images: images)
    if let limit = arguments.options["--limit"].flatMap(Int.init) { pairs = Array(pairs.prefix(limit)) }
    guard !pairs.isEmpty else {
        throw UsageError("no strip in \(images.path) has a reference in \(reference.path)")
    }
    printError("Evaluating \(configuration.label) on \(pairs.count) strips.")
    let recognizer = try await RecognizerFactory.make(configuration, libraryRoot: root)
    let outputs = await Evaluation.run(
        pairs,
        recognize: { try await recognizer.recognize(try StripCutter.scaled($0)) },
        progress: { n, output in
            let state = output.error != nil ? " (failed)" : (output.refused ? " (refused)" : "")
            printError(String(format: "%d/%d: %.2f s%@", n, pairs.count, output.seconds, state))
        }
    )
    await recognizer.unload()
    let scores = try Evaluation.score(pairs, outputs)
    print("Recognizer: \(configuration.label)")
    print("Prompt version: \(RecognitionPrompt.version)")
    print(Evaluation.table(scores))
    if let first = outputs.first {
        print(String(format: "The first strip, which includes loading the model, took %.2f s.", first.seconds))
    }
    if let out = arguments.options["--out"] {
        struct File: Codable {
            var recognizer: String
            var model: String
            var promptVersion: String
            var results: [Evaluation.Output]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            File(
                recognizer: configuration.label,
                model: configuration.keyModel,
                promptVersion: RecognitionPrompt.version,
                results: outputs
            )
        )
        .write(to: URL(filePath: out))
        printError("Wrote the outputs, which hold the recognized text, to \(out).")
    }
}

/// `repossess model ...`: the pinned MLX model's status, download, and hash check.
func modelCommand(_ arguments: Arguments) async throws {
    let store = ModelStore(libraryRoot: libraryRoot(arguments))
    let model = store.model
    let gigabytes = String(format: "%.2f GB", Double(model.totalBytes) / 1e9)
    switch arguments.positional.first {
    case "status", nil:
        print("Model: \(model.repository) at revision \(model.revision), \(model.files.count) files, \(gigabytes)")
        for (name, folder) in [
            ("rePossess's copy", store.libraryFolder), ("Hugging Face cache", store.huggingFaceSnapshot),
        ] {
            print("\(name): \(store.isComplete(folder) ? "complete" : "not complete") at \(folder.path)")
        }
        print(store.locate().map { "In use: \($0.path)" } ?? "In use: none. Run `repossess model download`.")

    case "verify":
        guard let folder = store.locate() else { throw UsageError("the model is not on this Mac") }
        printError("Checking the SHA-256 of \(model.files.count) files in \(folder.path).")
        let bad = try store.verify(folder)
        print(
            bad.isEmpty ? "Every file matches its pinned size and SHA-256." : "Differs: " + bad.joined(separator: ", ")
        )
        if !bad.isEmpty { exit(1) }

    case "download":
        if let folder = store.locate() {
            print("The model is already on this Mac, at \(folder.path). Nothing was downloaded.")
            return
        }
        printError(
            "Downloading \(model.repository) at revision \(model.revision) (\(gigabytes)) from huggingface.co "
                + "to \(store.libraryFolder.path). Stop it at any time; the next download continues."
        )
        let folder = try await store.download(progress: { printError($0) })
        print("Downloaded and checked \(model.files.count) files in \(folder.path).")

    default:
        throw UsageError("model needs status, verify, or download")
    }
}

/// Parses a page range such as `3` or `2-5`.
func pageRange(_ text: String?) throws -> ClosedRange<Int>? {
    guard let text else { return nil }
    let parts = text.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
    switch parts.count {
    case 1: if let n = parts[0], n >= 1 { return n ... n }
    case 2: if let a = parts[0], let b = parts[1], a >= 1, b >= a { return a ... b }
    default: break
    }
    throw UsageError("--pages takes a page or a range, such as 3 or 2-5")
}

/// `repossess recognize [<id>] [--pages A-B] [--again]`: reads the handwriting that the cache does not have.
func recognizeCommand(_ arguments: Arguments) async throws {
    let library = try Library(root: libraryRoot(arguments))
    guard let configuration = try RecognizerConfiguration.activate(in: library) else {
        throw UsageError("no recognizer is configured; run `repossess recognizer set` first")
    }
    let id = arguments.positional.first
    let range = try pageRange(arguments.options["--pages"])
    let again = arguments.flags.contains("--again")
    let documents = try id.map { [try PageLoader(library: library).document($0)] } ?? library.documents()
    var pages: [LibraryPage] = []
    for document in documents {
        for page in try library.pages(of: document.id) where page.strokeHash != nil {
            if let range, !range.contains(page.number) { continue }
            if !again, let hash = page.strokeHash,
                try library.recognition(strokeHash: hash, key: configuration.key) != nil
            {
                continue
            }
            pages.append(page)
        }
    }
    guard !pages.isEmpty else {
        print("Nothing to recognize: every page with handwriting has text from \(configuration.label).")
        return
    }
    printError("Recognizing \(pages.count) pages with \(configuration.label).")
    let recognizer = HandwritingRecognizer(
        library: library,
        configuration: configuration,
        recognizer: try await RecognizerFactory.make(configuration, libraryRoot: library.root)
    )
    let names = Dictionary(documents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let start = ContinuousClock.now
    let (results, _) = try await recognizer.recognize(pages, again: again) { result in
        let r = result.recognition
        let words = r.text.split(whereSeparator: \.isWhitespace).count
        printError(
            String(
                format: "%@ page %d: %@, %d strips, %d words, %.1f s",
                names[result.documentID] ?? result.documentID,
                result.pageNo,
                r.status.rawValue,
                r.strips,
                words,
                r.seconds
            )
        )
    }
    let elapsed = ContinuousClock.now - start
    let counts = Dictionary(grouping: results, by: \.recognition.status).mapValues(\.count)
    print(
        "Recognized \(results.count) pages in \(elapsed.components.seconds) s: "
            + "\(counts[.text] ?? 0) with text, \(counts[.empty] ?? 0) without words, \(counts[.refused] ?? 0) refused."
    )
}
