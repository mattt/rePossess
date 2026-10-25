import Foundation
import MCP

/// Serves the read tools over standard input and output until the client disconnects.
public func serveMCP(tools: ReadTools, version: String) async throws {
    let server = Server(
        name: "repossess",
        version: version,
        title: "rePossess",
        instructions: """
            rePossess serves the documents on the user's reMarkable tablet from a mirror on this Mac. \
            Call get_overview first. Use search_documents to find a document by a word, \
            and list_documents to browse folders; never guess a document id. \
            fetch_document returns typed text and PDF text as Markdown; \
            handwriting is not read as text yet, so look at it with fetch_page_image or fetch_page_chunks. \
            Pages are numbered from 1 in every tool. \
            If a document the user just made is missing, call refresh_documents.
            """,
        capabilities: .init(tools: .init(listChanged: false))
    )
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: ReadTools.all)
    }
    await server.withMethodHandler(CallTool.self) { params in
        await tools.call(params)
    }
    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
}
