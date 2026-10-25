import CoreGraphics
import Foundation
import MCP
import Testing

@testable import RePossessLibrary
@testable import RePossessMCP
@testable import RePossessRecognize

/// Reads every strip as the same text, or refuses, and counts its calls.
final class FixedReader: StripRecognizer, @unchecked Sendable {
    let text: String
    let refuses: Bool
    private let lock = NSLock()
    private var count = 0

    init(_ text: String, refuses: Bool = false) {
        self.text = text
        self.refuses = refuses
    }

    var calls: Int { lock.withLock { count } }

    func recognize(_ strip: CGImage) async throws -> StripAnswer {
        lock.withLock { count += 1 }
        return StripAnswer(text: refuses ? "" : text, refused: refuses)
    }
}

/// The stocked tools with a configured recognizer that `reader` stands in for.
func handwritingTools(
    _ configuration: RecognizerConfiguration? = try? RecognizerConfiguration(provider: .mlx),
    reader: FixedReader = FixedReader("Tomatoes along the south fence"),
    budget: Duration = .seconds(45),
    readiness: String? = nil
) async throws -> RePossessTools {
    let stocked = try await stockedTools()
    let library = stocked.library
    if let configuration { try configuration.save(to: library.root) }
    return RePossessTools(
        library: library,
        refresh: { _ in [] },
        usbConnected: { false },
        cloudPaired: { false },
        recognition: RecognitionContext(
            configuration: { try RecognizerConfiguration.activate(in: library) },
            makeRecognizer: { _ in reader },
            readiness: { _ in readiness },
            budget: budget
        )
    )
}

@Suite struct HandwritingToolTests {
    @Test func withoutARecognizerTheMarkersStay() async throws {
        let tools = try await handwritingTools(nil)
        let text = texts(await call(tools, "fetch_document", ["id": "doc-ink"]))[0]
        #expect(
            text.contains("[Handwriting or a drawing without text. Call fetch_page_image with page_no 1 to see it.]")
        )
        #expect(!text.contains("recognize_pages"))
        let result = await call(tools, "recognize_pages", ["id": "doc-ink"])
        #expect(result.isError == true && texts(result)[0].contains("Handwriting recognition is off"))
        let status = try json(await call(tools, "status"))["recognizer"] as! [String: Any]
        #expect(status["state"] as? String == "off")
    }

    @Test func aPageThatWaitsNamesRecognizePages() async throws {
        let tools = try await handwritingTools()
        let text = texts(await call(tools, "fetch_document", ["id": "doc-ink"]))[0]
        #expect(text.contains("not recognized as text yet. Call recognize_pages with id doc-ink"))
        #expect(text.contains("fetch_page_image with page_no 1"))
    }

    @Test func recognizePagesReadsAndFetchDocumentShowsTheText() async throws {
        let reader = FixedReader("Tomatoes along the south fence")
        let tools = try await handwritingTools(reader: reader)
        let result = await call(tools, "recognize_pages", ["id": "doc-ink"])
        #expect(result.isError != true)
        let read = texts(result)[0]
        #expect(read.contains("Handwriting, recognized as text:\n\nTomatoes along the south fence"))
        #expect(read.contains("provider mlx, model mlx-community/Qwen3-VL-8B-Instruct-4bit@"))
        #expect(read.contains("1 pages were read now"))
        #expect(reader.calls == 1)

        let fetched = texts(await call(tools, "fetch_document", ["id": "doc-ink"]))[0]
        #expect(
            fetched.contains(
                "Handwriting on these pages was recognized as text by Qwen3-VL 8B 4-bit (MLX, on this Mac)"
            )
        )
        #expect(fetched.contains("Tomatoes along the south fence"))
        #expect(!fetched.contains("fetch_page_image with page_no 1 to see it.]"))

        let search = try json(await call(tools, "search_documents", ["query": "tomatoes"]))
        let hits = search["results"] as! [[String: Any]]
        #expect(
            hits.count == 1 && hits[0]["match"] as? String == "handwriting" && hits[0]["id"] as? String == "doc-ink"
        )

        // A second call reads from the cache.
        let again = texts(await call(tools, "recognize_pages", ["id": "doc-ink"]))[0]
        #expect(again.contains("0 pages were read now") && again.contains("1 came from the cache"))
        #expect(reader.calls == 1)

        let status = try json(await call(tools, "status"))["recognizer"] as! [String: Any]
        #expect(status["state"] as? String == "ready" && status["provider"] as? String == "mlx")
        #expect(status["pages_with_handwriting"] as? Int == 2 && status["pages_recognized"] as? Int == 1)
        #expect(status["page_images_go_to"] as? String == "nowhere: recognition runs on this Mac")
    }

    @Test func aTypedPageKeepsItsTextAndAddsTheHandwriting() async throws {
        let tools = try await handwritingTools(reader: FixedReader("Ask about compost"))
        _ = await call(tools, "recognize_pages", ["id": "doc-typed", "pages": ["start": 2, "end": 2]])
        let text = texts(await call(tools, "fetch_document", ["id": "doc-typed"]))[0]
        #expect(text.contains("Budget notes\n\nHandwriting on this page, recognized as text:\n\nAsk about compost"))
    }

    @Test func aRefusalLeavesThePageForTheImage() async throws {
        let tools = try await handwritingTools(reader: FixedReader("", refuses: true))
        _ = await call(tools, "recognize_pages", ["id": "doc-ink"])
        let text = texts(await call(tools, "fetch_document", ["id": "doc-ink"]))[0]
        #expect(text.contains("declined to read. Call fetch_page_image with page_no 1"))
        let status = try json(await call(tools, "status"))["recognizer"] as! [String: Any]
        #expect(status["pages_refused"] as? Int == 1)
    }

    @Test func pagesWithoutHandwritingNeedNothing() async throws {
        let tools = try await handwritingTools()
        let text = texts(await call(tools, "recognize_pages", ["id": "doc-long", "pages": ["start": 1, "end": 2]]))[0]
        #expect(text.contains("These pages have no handwriting or drawings to recognize."))
    }

    @Test func anUnavailableRecognizerSaysWhy() async throws {
        let tools = try await handwritingTools(readiness: "The recognizer's model is not on this Mac.")
        let status = try json(await call(tools, "status"))["recognizer"] as! [String: Any]
        #expect(status["state"] as? String == "unavailable")
        #expect((status["note"] as? String)?.contains("not on this Mac") == true)
    }

    @Test func aBudgetOfZeroLeavesPagesForTheNextCall() async throws {
        let tools = try await handwritingTools(budget: .zero)
        let text = texts(await call(tools, "recognize_pages", ["id": "doc-typed"]))[0]
        #expect(text.contains("Stopped before page 2"))
        #expect(text.contains("Call recognize_pages with id doc-typed and pages {\"start\": 2, \"end\": 2}"))
    }
}

@Suite struct ClientSamplingTests {
    /// A server for the stocked library with the `client` recognizer, and a fake client connected to it.
    func connect(declaresSampling: Bool, answer: String = "Prune the apple tree") async throws -> (Client, Requests) {
        let stocked = try await stockedTools()
        let library = stocked.library
        try RecognizerConfiguration(provider: .client).save(to: library.root)
        let sampling = ClientSampling()
        let tools = RePossessTools(
            library: library,
            refresh: { _ in [] },
            usbConnected: { false },
            cloudPaired: { false },
            recognition: .live(library: library, sampler: sampling)
        )
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        _ = try await startServer(tools: tools, version: "test", sampling: sampling, transport: serverTransport)
        let requests = Requests()
        let client = Client(
            name: "fake",
            version: "1",
            capabilities: .init(sampling: declaresSampling ? .init() : nil)
        )
        await client.withSamplingHandler { params in
            requests.add(params)
            return .init(model: "fake-vision-1", stopReason: .endTurn, role: .assistant, content: .text(answer))
        }
        try await client.connect(transport: clientTransport)
        return (client, requests)
    }

    @Test func aClientThatSamplesReadsTheHandwriting() async throws {
        let (client, requests) = try await connect(declaresSampling: true)
        let (content, isError) = try await client.callTool(name: "recognize_pages", arguments: ["id": "doc-ink"])
        #expect(isError != true)
        guard case .text(let text, _, _) = content[0] else { Issue.record("no text"); return }
        #expect(text.contains("Prune the apple tree") && text.contains("provider client"))
        let sent = try #require(requests.all.first)
        #expect(sent.temperature == 0 && sent.maxTokens == RecognitionPrompt.maximumResponseTokens)
        let blocks = sent.messages[0].content.asArray
        #expect(blocks.count == 2)
        if case .image(_, let mimeType) = blocks[0] {
            #expect(mimeType == "image/png")
        } else {
            Issue.record("no image")
        }
        if case .text(let prompt) = blocks[1] {
            #expect(prompt == RecognitionPrompt.text)
        } else {
            Issue.record("no prompt")
        }

        let (fetched, _) = try await client.callTool(name: "fetch_document", arguments: ["id": "doc-ink"])
        guard case .text(let document, _, _) = fetched[0] else { Issue.record("no text"); return }
        #expect(document.contains("Prune the apple tree"))
    }

    @Test func aClientThatDoesNotSampleGetsTheMarkers() async throws {
        let (client, requests) = try await connect(declaresSampling: false)
        let (content, isError) = try await client.callTool(name: "recognize_pages", arguments: ["id": "doc-ink"])
        #expect(isError == true && requests.all.isEmpty)
        guard case .text(let text, _, _) = content[0] else { Issue.record("no text"); return }
        #expect(text.contains("does not declare the sampling capability"))
        let (fetched, _) = try await client.callTool(name: "fetch_document", arguments: ["id": "doc-ink"])
        guard case .text(let document, _, _) = fetched[0] else { Issue.record("no text"); return }
        #expect(document.contains("[Handwriting or a drawing without text. Call fetch_page_image with page_no 1"))
        #expect(!document.contains("recognize_pages"))
    }
}

final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CreateSamplingMessage.Parameters] = []
    func add(_ request: CreateSamplingMessage.Parameters) { lock.withLock { requests.append(request) } }
    var all: [CreateSamplingMessage.Parameters] { lock.withLock { requests } }
}
