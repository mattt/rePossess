import Foundation
import MCP

/// The server's instructions to the client.
public let serverInstructions = """
    rePossess serves the documents on the user's reMarkable tablet from a mirror on this Mac. \
    Call get_overview first. Use search_documents to find a document by a word, \
    and list_documents to browse folders; never guess a document id. \
    fetch_document returns typed text and PDF text as Markdown. \
    When the owner has configured a handwriting recognizer, it also returns handwriting as recognized text, \
    labeled with the recognizer, and recognize_pages reads pages that wait; recognized text can have errors. \
    Otherwise, look at handwriting with fetch_page_image or fetch_page_chunks; \
    each page's marker says which tool to call. \
    Pages are numbered from 1 in every tool. \
    Each document has a file_type (notebook, pdf, or epub) and a content_status: \
    ink is a handwritten notebook, annotated is a PDF or EPUB with handwriting on its pages, \
    and image is a PDF or EPUB whose pages have no text layer, such as a scan. \
    If a document the user just made is missing, call refresh_documents. \
    push_markdown and push_file add a new document to the tablet with every call; \
    never call them to retry, and call them only when the user asks to send something.
    """

/// Starts the tools' server on a transport.
///
/// When the client declares the `sampling` capability in `initialize`, `sampling` records it,
/// so that the `client` recognizer can ask the client's model to read handwriting.
public func startServer(
    tools: RePossessTools,
    version: String,
    sampling: ClientSampling? = nil,
    transport: any Transport
) async throws -> Server {
    let server = Server(
        name: "repossess",
        version: version,
        title: "rePossess",
        instructions: serverInstructions,
        capabilities: .init(tools: .init(listChanged: false))
    )
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: RePossessTools.all)
    }
    await server.withMethodHandler(CallTool.self) { params in
        await tools.call(params)
    }
    await sampling?.attach(server)
    try await server.start(transport: transport) { _, capabilities in
        await sampling?.setDeclared(capabilities.sampling != nil)
    }
    return server
}

/// Serves the tools over standard input and output until the client disconnects.
public func serveMCP(tools: RePossessTools, version: String, sampling: ClientSampling? = nil) async throws {
    let server = try await startServer(tools: tools, version: version, sampling: sampling, transport: StdioTransport())
    await server.waitUntilCompleted()
}
