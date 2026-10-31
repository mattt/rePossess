import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import RePossessFormat
@testable import RePossessLibrary
@testable import RePossessRecognize
@testable import RePossessRender

/// A recognizer that answers from a list, records the size of each strip, and can refuse.
final class FakeStripRecognizer: StripRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [StripAnswer]
    private(set) var sizes: [(Int, Int)] = []
    private(set) var unloads = 0
    let delay: Duration

    init(_ answers: [StripAnswer], delay: Duration = .zero) {
        self.answers = answers
        self.delay = delay
    }

    var calls: Int { lock.withLock { sizes.count } }

    func recognize(_ strip: CGImage) async throws -> StripAnswer {
        if delay > .zero { try await Task.sleep(for: delay) }
        return lock.withLock {
            sizes.append((strip.width, strip.height))
            return answers.isEmpty ? StripAnswer(text: "more words") : answers.removeFirst()
        }
    }

    func unload() async { lock.withLock { unloads += 1 } }
}

/// A library with one invented notebook: a long page of ink in two blocks, a page of text, and a short page of ink.
func notebookLibrary() throws -> Library {
    var long = PageBuilder()
    long.groups = [
        .init(lines: [
            PageBuilder.stroke([(-300, 200), (300, 220)]),
            PageBuilder.stroke([(-300, 1500), (300, 1520)]),
            // Below one screen: the page grows, and the cutter must cut in the blank rows between.
            PageBuilder.stroke([(-300, 2600), (300, 2620)]),
        ])
    ]
    var typed = PageBuilder()
    typed.paragraphs = [StyledParagraph(.plain, "Typed words only")]
    var short = PageBuilder()
    short.groups = [.init(lines: [PageBuilder.stroke([(-100, 400), (100, 420)])])]
    let builder = DocumentBuilder(
        id: "d0000000-0000-4000-8000-0000000000aa",
        name: "Allotment",
        pages: [("n-1", long), ("n-2", typed), ("n-3", short)]
    )
    let library = try Library(
        root: FileManager.default.temporaryDirectory.appending(path: "repossess-recognize-\(UUID().uuidString)")
    )
    let archive = try RmdocArchive(data: try builder.rmdoc())
    let folder = try archive.unpack(into: library.root.appending(path: "documents/\(builder.id)"), as: builder.id)
    try library.importForChecking(folder)
    return library
}

func image(width: Int, height: Int, inkRows: [ClosedRange<Int>]) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 0, alpha: 1)
    for rows in inkRows {
        // Core Graphics puts y 0 at the bottom; the cutter counts rows from the top.
        context.fill(CGRect(x: 10, y: height - rows.upperBound - 1, width: 50, height: rows.count))
    }
    return context.makeImage()!
}

@Suite struct ScoringTests {
    @Test func normalizesAsScorePyDoes() {
        #expect(Scoring.normalize("Hello, World & [[Friends]]!") == "hello world and friends")
        #expect(Scoring.normalize("- a_b → don't\n\tC3") == "a b don t c3")
        #expect(Scoring.normalize("Café") == "café")
    }

    @Test func countsEditsAndRecall() {
        let counts = Scoring.score(reference: "the cat sat on the mat", output: "the cat sat on mat today")
        #expect(counts.referenceWords == 6 && counts.wordEdits == 2 && counts.wordsFound == 5)
        #expect(counts.wordErrorRate == 2.0 / 6.0)
        let exact = Scoring.score(reference: "Seed order", output: "seed  ORDER.")
        #expect(exact.wordEdits == 0 && exact.characterEdits == 0 && exact.wordRecall == 1)
        let empty = Scoring.score(reference: "", output: "anything")
        #expect(empty.wordErrorRate == nil && empty.referenceWords == 0)
        #expect(Scoring.score(reference: "abc", output: "abd").characterEdits == 1)
    }

    @Test func recallIgnoresOrderButCountsRepeats() {
        let counts = Scoring.score(reference: "red red blue", output: "blue red")
        #expect(counts.wordsFound == 2)
    }

    @Test func warmMedianLeavesOutTheFirstStrip() {
        #expect(Evaluation.warmMedian([9, 1, 3, 2]) == 2)
        #expect(Evaluation.warmMedian([9, 1, 3]) == 2)
        #expect(Evaluation.warmMedian([4]) == 4)
        #expect(Evaluation.warmMedian([]) == nil)
    }
}

@Suite struct RefusalTests {
    @Test func findsRefusalsWrittenAsText() {
        #expect(RefusalDetector.isRefusal("I'm sorry, but I can't help with transcribing this image."))
        #expect(RefusalDetector.isRefusal("I cannot assist with that request."))
        #expect(RefusalDetector.isRefusal("I\u{2019}m unable to read the handwriting in this image."))
        #expect(RefusalDetector.isRefusal("Sorry, I can't provide a transcription of this content."))
    }

    @Test func leavesHandwritingAlone() {
        #expect(!RefusalDetector.isRefusal("I'm sorry I missed the meeting\n- call Sam back"))
        #expect(!RefusalDetector.isRefusal("Groceries\n- I cannot forget the eggs"))
        #expect(!RefusalDetector.isRefusal(""))
        let long = "I'm sorry this image " + String(repeating: "is long ", count: 80)
        #expect(!RefusalDetector.isRefusal(long))
    }
}

@Suite struct StripTests {
    @Test func cutsInTheMiddleOfTheLongestBlankRun() {
        var rows = [Int](repeating: 0, count: 3000)
        for y in 100 ..< 200 { rows[y] = 5 }
        for y in 1200 ..< 1300 { rows[y] = 5 }
        for y in 1500 ..< 1600 { rows[y] = 5 }
        for y in 2500 ..< 2600 { rows[y] = 5 }
        let cuts = StripCutter.cuts(rows, maxHeight: 1872)
        // Between 936 and 1872, the longest blank run is 1600 to 1872, so the cut is at its middle.
        #expect(cuts.map(\.top) == [0, 1736])
        #expect(cuts[0].bottom == 1736 && !cuts[0].hard && cuts[1].bottom == 3000)
    }

    @Test func cutsThroughInkWhenThereIsNoBlankRow() {
        let rows = [Int](repeating: 1, count: 2000)
        let cuts = StripCutter.cuts(rows, maxHeight: 1872)
        #expect(cuts.count == 2 && cuts[0].hard && cuts[0].bottom == 1872)
    }

    @Test func skipsStripsWithoutInk() {
        let picture = image(width: 100, height: 4000, inkRows: [100 ... 120])
        let strips = StripCutter.strips(picture)
        #expect(strips.count == 1 && strips[0].top == 0)
    }

    @Test func scalesTheLongerSideTo936() throws {
        let scaled = try StripCutter.scaled(image(width: 1404, height: 1872, inkRows: [10 ... 20]))
        #expect(scaled.width == 702 && scaled.height == 936)
        let small = image(width: 400, height: 300, inkRows: [])
        #expect(try StripCutter.scaled(small).width == 400)
    }

    @Test func aLongPageGivesSeveralStripsOfItsStrokes() throws {
        let library = try notebookLibrary()
        let page = try library.pages(of: "d0000000-0000-4000-8000-0000000000aa")[0]
        let strips = try StripCutter.strips(try HandwritingRecognizer.scene(library, page))
        #expect(strips.count == 2)
        #expect(strips.allSatisfy { $0.bottom - $0.top <= StripCutter.maxHeight && !$0.hardCut })
        #expect(strips[0].image.width == 1404)
    }
}

@Suite struct ConfigurationTests {
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "repossess-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func offByDefault() throws {
        #expect(try RecognizerConfiguration.load(from: try root()) == nil)
    }

    @Test func localProvidersSendNothing() throws {
        let mlx = try RecognizerConfiguration(provider: .mlx)
        #expect(!mlx.sendsPageImages && mlx.destination == "nowhere: recognition runs on this Mac")
        #expect(mlx.key.model == "mlx-community/Qwen3-VL-8B-Instruct-4bit@defcdea7cc7a4b0858fea563cbbce171d328e457")
        #expect(mlx.key.promptVersion == RecognitionPrompt.version)
        #expect(!(try RecognizerConfiguration(provider: .foundationModels)).sendsPageImages)
        let ollama = try RecognizerConfiguration(provider: .ollama, model: "qwen3-vl")
        #expect(!ollama.sendsPageImages)
    }

    @Test func cloudProvidersSayWherePagesGo() throws {
        let anthropic = try RecognizerConfiguration(provider: .anthropic, model: "a-vision-model")
        #expect(anthropic.sendsPageImages && anthropic.receivingHost == "api.anthropic.com")
        #expect(anthropic.destination.hasPrefix("api.anthropic.com (Anthropic)"))
        let remote = try RecognizerConfiguration(
            provider: .ollama,
            model: "m",
            baseURL: URL(string: "https://ollama.example.org")
        )
        #expect(remote.sendsPageImages && remote.receivingHost == "ollama.example.org")
        #expect(try RecognizerConfiguration(provider: .client).sendsPageImages)
    }

    @Test func refusesIncompleteChoices() {
        #expect(throws: RecognizerError.self) { try RecognizerConfiguration(provider: .anthropic) }
        #expect(throws: RecognizerError.self) { try RecognizerConfiguration(provider: .mlx, model: "other/model") }
        #expect(throws: RecognizerError.self) {
            try RecognizerConfiguration(provider: .openai, model: "m", baseURL: URL(string: "http://example.org"))
        }
    }

    @Test func savesWithoutAKeyAndLoadsAgain() throws {
        let root = try root()
        let configuration = try RecognizerConfiguration(provider: .gemini, model: "g-vision")
        try configuration.save(to: root)
        let text = try String(contentsOf: RecognizerConfiguration.url(in: root), encoding: .utf8)
        #expect(text.contains("\"page_images_go_to\" : \"generativelanguage.googleapis.com (Google)"))
        #expect(!text.lowercased().contains("key"))
        let loaded = try #require(try RecognizerConfiguration.load(from: root))
        #expect(loaded.provider == .gemini && loaded.model == "g-vision" && loaded.key == configuration.key)
        #expect(try RecognizerConfiguration.remove(from: root))
        #expect(try RecognizerConfiguration.load(from: root) == nil)
    }

    @Test func activateSetsTheLibrarysKey() throws {
        let library = try notebookLibrary()
        try RecognizerConfiguration(provider: .foundationModels).save(to: library.root)
        let configuration = try RecognizerConfiguration.activate(in: library)
        #expect(try library.activeRecognitionKey() == configuration?.key)
        try RecognizerConfiguration.remove(from: library.root)
        try RecognizerConfiguration.activate(in: library)
        #expect(try library.activeRecognitionKey() == nil)
    }
}

@Suite struct APIKeyTests {
    @Test func theEnvironmentComesBeforeTheKeychain() throws {
        let store = FakeAPIKeyStore(["anthropic": "from-keychain"])
        let key = try APIKeys.key(for: .anthropic, environment: ["ANTHROPIC_API_KEY": "from-env"], store: store)
        #expect(key == "from-env" && store.reads.isEmpty)
        #expect(try APIKeys.key(for: .anthropic, environment: [:], store: store) == "from-keychain")
        #expect(try APIKeys.key(for: .gemini, environment: ["GOOGLE_API_KEY": "g"], store: store) == "g")
    }

    @Test func aMissingKeySaysWhereToPutOne() {
        #expect(throws: RecognizerError.self) {
            try APIKeys.key(for: .openai, environment: [:], store: FakeAPIKeyStore())
        }
        #expect(APIKeys.source(for: .openai, environment: [:], store: FakeAPIKeyStore()) == nil)
        let store = FakeAPIKeyStore(["openai": "k"])
        #expect(APIKeys.source(for: .openai, environment: [:], store: store) == "the login keychain")
        #expect(store.reads.isEmpty)
    }

    @Test func makingACloudRecognizerWithoutAKeyFails() async throws {
        let configuration = try RecognizerConfiguration(provider: .anthropic, model: "m")
        await #expect(throws: RecognizerError.self) {
            _ = try await RecognizerFactory.make(
                configuration,
                libraryRoot: FileManager.default.temporaryDirectory,
                environment: [:],
                keys: FakeAPIKeyStore()
            )
        }
    }
}

/// Serves bytes from memory, honoring or ignoring the range, and can stop early.
final class FakeFetcher: RangeFetcher, @unchecked Sendable {
    let files: [String: Data]
    let honorsRange: Bool
    let stopAfter: Int?
    private let lock = NSLock()
    private(set) var offsets: [Int64] = []

    init(_ files: [String: Data], honorsRange: Bool = true, stopAfter: Int? = nil) {
        self.files = files
        self.honorsRange = honorsRange
        self.stopAfter = stopAfter
    }

    func fetch(_ url: URL, from offset: Int64, into file: FileHandle, progress: @escaping @Sendable (Int64) -> Void)
        async throws
    {
        lock.withLock { offsets.append(offset) }
        let data = files[url.lastPathComponent] ?? Data()
        var body = data
        if honorsRange {
            body = data.dropFirst(Int(offset))
        } else {
            try file.truncate(atOffset: 0)
        }
        if let stopAfter, body.count > stopAfter {
            try file.write(contentsOf: body.prefix(stopAfter))
            throw URLError(.networkConnectionLost)
        }
        try file.write(contentsOf: body)
        progress(Int64(body.count))
    }
}

@Suite struct ModelStoreTests {
    let weights = Data((0 ..< 1000).map { UInt8($0 % 251) })
    let config = Data(#"{"model_type": "qwen3_vl"}"#.utf8)

    var model: PinnedModel {
        PinnedModel(
            repository: "example/tiny-vl",
            revision: "0123abcd",
            files: [
                .init(name: "config.json", bytes: Int64(config.count), sha256: sha(config)),
                .init(name: "model.safetensors", bytes: Int64(weights.count), sha256: sha(weights)),
            ]
        )
    }

    func path(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    func sha(_ data: Data) -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "sha-\(UUID().uuidString)")
        try? data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? ModelStore.sha256(url)) ?? ""
    }

    func store(environment: [String: String] = ["HF_HUB_CACHE": "/nonexistent"]) -> ModelStore {
        ModelStore(
            model: model,
            libraryRoot: FileManager.default.temporaryDirectory.appending(
                path: "repossess-models-\(UUID().uuidString)"
            ),
            environment: environment
        )
    }

    @Test func findsTheHuggingFaceCacheSnapshot() throws {
        let hub = FileManager.default.temporaryDirectory.appending(path: "hub-\(UUID().uuidString)")
        let store = store(environment: ["HF_HUB_CACHE": hub.path])
        #expect(store.locate() == nil)
        let snapshot = hub.appending(path: "models--example--tiny-vl/snapshots/0123abcd")
        #expect(path(store.huggingFaceSnapshot) == path(snapshot))
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try config.write(to: snapshot.appending(path: "config.json"))
        #expect(store.locate() == nil)
        // The cache links each file to a blob.
        let blob = hub.appending(path: "blob-weights")
        try weights.write(to: blob)
        try FileManager.default.createSymbolicLink(
            at: snapshot.appending(path: "model.safetensors"),
            withDestinationURL: blob
        )
        #expect(store.locate().map(path) == path(snapshot))
        #expect(try store.verify(snapshot).isEmpty)
        try Data(count: weights.count).write(to: blob)
        #expect(try store.verify(snapshot) == ["model.safetensors"])
    }

    @Test func downloadsAndChecksEveryFile() async throws {
        let store = store()
        let fetcher = FakeFetcher(["config.json": config, "model.safetensors": weights])
        let lines = Lines()
        let folder = try await store.download(fetcher: fetcher, progress: { lines.add($0) })
        #expect(folder == store.libraryFolder && store.locate() == folder)
        #expect(try store.verify(folder).isEmpty)
        #expect(lines.all.contains("model.safetensors: checked"))
        // A second download finds every file and fetches nothing.
        let again = FakeFetcher([:])
        _ = try await store.download(fetcher: again, progress: { _ in })
        #expect(again.offsets.isEmpty)
    }

    @Test func reportsTheBytesForAProgressBar() async throws {
        let store = store()
        let fetcher = FakeFetcher(["config.json": config, "model.safetensors": weights])
        let counts = Lines()
        _ = try await store.download(
            fetcher: fetcher,
            progress: { _ in },
            bytes: { done, total in counts.add("\(done)/\(total)") }
        )
        let total = model.totalBytes
        #expect(counts.all.last == "\(total)/\(total)")
        let done = counts.all.compactMap { Int64($0.split(separator: "/")[0]) }
        #expect(done == done.sorted() && !done.isEmpty)
    }

    @Test func continuesAPartialFile() async throws {
        let store = store()
        await #expect(throws: RecognizerError.self) {
            _ = try await store.download(
                fetcher: FakeFetcher(["config.json": config, "model.safetensors": weights], stopAfter: 400),
                progress: { _ in }
            )
        }
        let part = store.libraryFolder.appending(path: "model.safetensors.part")
        #expect(store.size(part) == 400)
        let fetcher = FakeFetcher(["config.json": config, "model.safetensors": weights])
        _ = try await store.download(fetcher: fetcher, progress: { _ in })
        #expect(fetcher.offsets == [400])
        #expect(try store.verify(store.libraryFolder).isEmpty)
    }

    @Test func startsAgainWhenTheServerIgnoresTheRange() async throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.libraryFolder, withIntermediateDirectories: true)
        try config.write(to: store.libraryFolder.appending(path: "config.json"))
        try weights.prefix(300).write(to: store.libraryFolder.appending(path: "model.safetensors.part"))
        _ = try await store.download(
            fetcher: FakeFetcher(["model.safetensors": weights], honorsRange: false),
            progress: { _ in }
        )
        #expect(try store.verify(store.libraryFolder).isEmpty)
    }

    @Test func deletesAFileWhoseHashDiffers() async throws {
        let store = store()
        var corrupt = weights
        corrupt[10] ^= 0xFF
        await #expect(throws: RecognizerError.self) {
            _ = try await store.download(
                fetcher: FakeFetcher(["config.json": config, "model.safetensors": corrupt]),
                progress: { _ in }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: store.libraryFolder.appending(path: "model.safetensors").path))
        #expect(
            !FileManager.default.fileExists(atPath: store.libraryFolder.appending(path: "model.safetensors.part").path)
        )
    }

    @Test func thePinnedModelNamesItsRevisionAndSize() {
        let pinned = PinnedModel.qwen3VL8B
        #expect(pinned.repository == "mlx-community/Qwen3-VL-8B-Instruct-4bit")
        #expect(pinned.revision == "defcdea7cc7a4b0858fea563cbbce171d328e457")
        #expect(pinned.totalBytes == 5_776_630_909)
        #expect(pinned.files.allSatisfy { $0.sha256.count == 64 })
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite struct HandwritingRecognizerTests {
    let id = "d0000000-0000-4000-8000-0000000000aa"

    func reader(_ library: Library, _ fake: FakeStripRecognizer) throws -> HandwritingRecognizer {
        let configuration = try RecognizerConfiguration(provider: .foundationModels)
        try library.setActiveRecognitionKey(configuration.key)
        return HandwritingRecognizer(library: library, configuration: configuration, recognizer: fake)
    }

    @Test func readsEachStripScaledAndJoinsTheText() async throws {
        let library = try notebookLibrary()
        let fake = FakeStripRecognizer([StripAnswer(text: "Leeks and chard"), StripAnswer(text: "Water on Sunday")])
        let reader = try reader(library, fake)
        let page = try library.pages(of: id)[0]
        let result = try await reader.recognize(page)
        #expect(!result.cached && result.recognition.status == .text)
        #expect(result.recognition.text == "Leeks and chard\nWater on Sunday" && result.recognition.strips == 2)
        #expect(fake.sizes.allSatisfy { max($0.0, $0.1) <= StripCutter.maxSide })
        #expect(result.recognition.label == "Apple's on-device Foundation Models model (on this Mac)")
        // The second time comes from the cache, and search finds it.
        let again = try await reader.recognize(page)
        #expect(again.cached && fake.calls == 2)
        #expect(try library.search("chard").hits.map(\.match) == [.handwriting])
    }

    @Test func aRefusedStripLeavesThePageUnread() async throws {
        let library = try notebookLibrary()
        let fake = FakeStripRecognizer([StripAnswer(text: "Leeks"), StripAnswer(text: "", refused: true)])
        let result = try await reader(library, fake).recognize(try library.pages(of: id)[0])
        #expect(result.recognition.status == .refused && result.recognition.text.isEmpty)
        #expect(try library.search("leeks").total == 0)
        // With again, the page is read once more.
        let retry = try await reader(library, FakeStripRecognizer([])).recognize(
            try library.pages(of: id)[0],
            again: true
        )
        #expect(retry.recognition.status == .text)
    }

    @Test func aPageWithoutWordsIsEmpty() async throws {
        let library = try notebookLibrary()
        let result = try await reader(library, FakeStripRecognizer([StripAnswer(text: "")])).recognize(
            try library.pages(of: id)[2]
        )
        #expect(result.recognition.status == .empty)
    }

    @Test func stopsStartingPagesAtTheDeadlineAndUnloads() async throws {
        let library = try notebookLibrary()
        let fake = FakeStripRecognizer([], delay: .milliseconds(30))
        let pages = try library.pages(of: id).filter { $0.strokeHash != nil }
        let (results, remaining) = try await reader(library, fake).recognize(
            pages,
            deadline: ContinuousClock.now + .milliseconds(10)
        )
        #expect(results.count == 1 && remaining.map(\.number) == [3])
        #expect(fake.unloads == 1)
    }

    @Test func aSecondProcessWaitsForTheLock() async throws {
        let library = try notebookLibrary()
        let fake = FakeStripRecognizer([], delay: .milliseconds(200))
        let reader = try reader(library, fake)
        let pages = try library.pages(of: id).filter { $0.strokeHash != nil }
        async let first = reader.recognize(pages)
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: RecognizerError.self) { _ = try await reader.recognize(pages) }
        _ = try await first
    }
}

@Suite struct EvaluationTests {
    @Test func pairsReferencesWithStripsAndScoresThem() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "repossess-eval-\(UUID().uuidString)")
        let reference = base.appending(path: "reference/notebook")
        let strips = base.appending(path: "strips/notebook")
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: strips, withIntermediateDirectories: true)
        try "Plant the garlic".write(to: reference.appending(path: "p01-s01.txt"), atomically: true, encoding: .utf8)
        try "Mend the fence".write(to: reference.appending(path: "p02-s01.txt"), atomically: true, encoding: .utf8)
        try "No image".write(to: reference.appending(path: "p03-s01.txt"), atomically: true, encoding: .utf8)
        try "Notes".write(to: base.appending(path: "reference/NOTES.md"), atomically: true, encoding: .utf8)
        for name in ["p01-s01", "p02-s01"] {
            let png = try StripCutter.png(image(width: 200, height: 100, inkRows: [10 ... 20]))
            try png.write(to: strips.appending(path: name + ".png"))
        }
        let pairs = try Evaluation.pairs(
            reference: base.appending(path: "reference"),
            images: base.appending(path: "strips")
        )
        #expect(pairs.map(\.name) == ["notebook/p01-s01", "notebook/p02-s01"])
        let answers = Answers([StripAnswer(text: "Plant the garlic"), StripAnswer(text: "", refused: true)])
        let outputs = await Evaluation.run(pairs, recognize: { _ in answers.next() })
        #expect(outputs.map(\.image) == ["notebook/p01-s01.png", "notebook/p02-s01.png"] && outputs[1].refused)
        let scores = try Evaluation.score(pairs, outputs)
        #expect(scores.map(\.name) == ["all", "notebook"])
        #expect(scores[0].counts.referenceWords == 6 && scores[0].counts.wordEdits == 3 && scores[0].refused == 1)
        #expect(Evaluation.table(scores).contains("50.0%"))
    }
}

final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [StripAnswer]
    init(_ answers: [StripAnswer]) { self.answers = answers }
    func next() -> StripAnswer { lock.withLock { answers.removeFirst() } }
}
