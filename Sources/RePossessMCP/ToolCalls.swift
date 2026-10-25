import Foundation
import MCP
import RePossessFormat
import RePossessLibrary
import RePossessRecognize
import RePossessRender

extension RePossessTools {
    // MARK: get_overview

    func overview(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let limit = min(max(try Self.integer(arguments, "limit") ?? 10, 1), 50)
        let configuration = await shownConfiguration()
        let status = try library.status()
        let documents = try library.documents()
        var out = "# reMarkable library\n\n"
        out += "\(status.documents) documents in \(status.folders) folders, \(status.pages) pages."
        out += " " + refreshSentence(status) + "\n"
        for source in [Source.usb, .cloud] {
            if let error = status.lastError[source] {
                let when = status.lastErrorAt[source].map { " at \(Self.date($0))" } ?? ""
                out += "\nThe last refresh from \(Self.sourceName(source)) failed\(when): \(error)\n"
            }
        }
        if documents.isEmpty {
            out += "\nThe library is empty. Call refresh_documents to read the tablet.\n"
            return Self.text(out)
        }
        out += "\n## Most recently changed\n"
        let recent = documents.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(limit)
        for (i, document) in recent.enumerated() {
            out += "\n\(i + 1). \(document.name)\n"
            out +=
                "   id: \(document.id) · \(document.fileType ?? "notebook") · path: \(document.path) · \(document.pageCount) pages"
            out += " · modified \(Self.date(document.modified)) · \(document.contentStatus.rawValue)\n"
            if let error = document.error {
                out += "   This document could not be read: \(error)\n"
            } else if !document.summary.isEmpty {
                out += "   Starts: \(document.summary)\n"
            }
            if document.error == nil, document.contentStatus != .text || document.summary.isEmpty {
                out += try handwritingSummary(document, configuration)
            }
        }
        out += """

            Call search_documents to find a document by a word, list_documents to browse folders, \
            and fetch_document with an id to read one. Never guess an id.

            """
        return Self.text(out)
    }

    /// A line for the overview about a document's handwriting: recognized text and its first words,
    /// pages that wait for the recognizer, or the page images.
    func handwritingSummary(_ document: LibraryItem, _ configuration: RecognizerConfiguration?) throws -> String {
        let ink = try library.pages(of: document.id).filter { $0.strokeHash != nil }
        guard !ink.isEmpty else {
            return document.summary.isEmpty && document.contentStatus != .text
                ? "   Pages without text; fetch_page_image shows a page.\n" : ""
        }
        guard let configuration else {
            return "   Handwriting or drawings without text; fetch_page_image shows a page.\n"
        }
        var texts: [String] = []
        var waiting = 0
        for page in ink {
            switch try handwriting(page, configuration) {
            case .recognized(let r) where r.status == .text: texts.append(r.text)
            case .waiting: waiting += 1
            default: break
            }
        }
        var line = ""
        if !texts.isEmpty {
            let words = texts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let start = words.count > 160 ? String(words.prefix(159)) + "…" : words
            line += "   Handwriting on \(texts.count) of \(ink.count) pages is recognized as text; "
            line += "fetch_document returns it. Starts: \(start)\n"
        }
        if waiting > 0 {
            line += "   \(waiting) pages of handwriting are not recognized yet; recognize_pages reads them, "
            line += "and fetch_page_image shows a page.\n"
        }
        return line.isEmpty
            ? "   Handwriting or drawings that the recognizer could not read; fetch_page_image shows a page.\n" : line
    }

    func refreshSentence(_ status: LibraryStatus) -> String {
        var sentence = mirrorSentence(status)
        let others = status.lastRefresh.filter { $0.key != status.latestRefresh?.source }
        for (source, date) in others {
            sentence += " The last refresh from \(Self.sourceName(source)) finished at \(Self.date(date))."
        }
        return sentence
    }

    // MARK: list_documents

    struct FolderEntry: Codable {
        let id: String
        let name: String
        var kind = "CollectionType"
        let parent: String
        let path: String
    }

    struct PageTagEntry: Codable {
        let page_no: Int
        let tag: String
    }

    struct DocumentEntry: Codable {
        let id: String
        let name: String
        var kind = "DocumentType"
        let parent: String
        let path: String
        let modified: String
        /// `notebook`, `pdf`, or `epub`, from the document's `.content` file.
        let file_type: String
        let page_count: Int
        let content_status: String
        let summary: String
        let tags: [String]
        let page_tags: [PageTagEntry]
        /// `usb` or `cloud`: where the mirror's copy of the document came from.
        let source: String
    }

    struct ListResult: Codable {
        let folders: [FolderEntry]
        let documents: [DocumentEntry]
        let mirror: MirrorEntry?
    }

    static func entry(_ item: LibraryItem) -> DocumentEntry {
        DocumentEntry(
            id: item.id,
            name: item.name,
            parent: item.parent,
            path: item.path,
            modified: date(item.modified),
            file_type: item.fileType ?? "notebook",
            page_count: item.pageCount,
            content_status: item.contentStatus.rawValue,
            summary: item.error.map { "This document could not be read: \($0)" } ?? item.summary,
            tags: item.tags,
            page_tags: item.pageTags.map { PageTagEntry(page_no: $0.pageNo, tag: $0.tag) },
            source: item.source.rawValue
        )
    }

    func listDocuments(_ arguments: [String: Value]) throws -> CallTool.Result {
        let tag = Self.string(arguments, "tag")
        let items = try library.items()
        let folders = items.filter { $0.kind == .folder }.map {
            FolderEntry(id: $0.id, name: $0.name, parent: $0.parent, path: $0.path)
        }
        let documents = items.filter { item in
            item.kind == .document
                && (tag == nil || item.tags.contains(tag!) || item.pageTags.contains { $0.tag == tag })
        }
        return try Self.json(ListResult(folders: folders, documents: documents.map(Self.entry), mirror: try mirror()))
    }

    // MARK: search_documents

    struct SearchEntry: Codable {
        let id: String
        let name: String
        let path: String
        let file_type: String
        let content_status: String
        let match: String
        let page_no: Int?
        let snippet: String
    }

    struct SearchResult: Codable {
        let query: String
        let total: Int
        let results: [SearchEntry]
        let mirror: MirrorEntry?
    }

    func searchDocuments(_ arguments: [String: Value]) throws -> CallTool.Result {
        guard let query = Self.string(arguments, "query"), !query.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw ToolError("query is required.") }
        let limit = min(max(try Self.integer(arguments, "limit") ?? 50, 1), 200)
        let (hits, total) = try library.search(query, limit: limit, tag: Self.string(arguments, "tag"))
        let results = hits.map {
            SearchEntry(
                id: $0.item.id,
                name: $0.item.name,
                path: $0.item.path,
                file_type: $0.item.fileType ?? "notebook",
                content_status: $0.item.contentStatus.rawValue,
                match: $0.match.rawValue,
                page_no: $0.pageNo,
                snippet: $0.snippet
            )
        }
        return try Self.json(SearchResult(query: query, total: total, results: results, mirror: try mirror()))
    }

    // MARK: fetch_document

    /// A page's text, and its handwriting as recognized text or as a marker that names the tool to call.
    static func pageBody(_ page: LibraryPage, _ handwriting: PageHandwriting = .notShown, documentID: String) -> String
    {
        var parts: [String] = []
        // The Markdown holds typed text and PDF text, and a placeholder for each image in reading order.
        if !page.markdown.isEmpty { parts.append(page.markdown) }
        if let part = handwritingPart(page, handwriting, documentID: documentID) { parts.append(part) }
        if !page.warnings.isEmpty {
            parts.append("[Part of this page could not be read; fetch_page_image shows what rePossess could draw.]")
        }
        return parts.isEmpty ? "[Blank page.]" : parts.joined(separator: "\n\n")
    }

    func fetchDocument(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let ids: [String]
        switch (Self.string(arguments, "id"), arguments["ids"]?.arrayValue) {
        case (let id?, nil):
            ids = [id]
        case (nil, let array?):
            ids = array.compactMap(\.stringValue)
            guard (1 ... 8).contains(ids.count), ids.count == array.count else {
                throw ToolError("ids must hold 1 to 8 document IDs.")
            }
        default:
            throw ToolError("Give exactly one of id or ids.")
        }
        let documents = try ids.map(loader.document)
        let range = arguments["pages"]?.objectValue ?? [:]
        let requestedStart = try Self.integer(range, "start") ?? 1
        let requestedEnd = try Self.integer(range, "end")

        let status = try library.status()
        let configuration = await shownConfiguration()
        var budget = Self.textBudget
        var blocks: [String] = []
        var returnedDocuments = 0
        var returnedPages = 0
        for document in documents {
            let pages = try library.pages(of: document.id)
            var block = "# \(document.name)\n\nid: \(document.id) · path: \(document.path) · "
            block += "\(pages.count) pages · modified \(Self.date(document.modified))"
            block += " · copied from \(Self.sourceName(document.source))\n"
            if blocks.isEmpty { block += mirrorSentence(status) + "\n" }
            if let error = document.error {
                block += "\nThis document could not be read: \(error)\n"
            }
            guard !pages.isEmpty else {
                blocks.append(block)
                returnedDocuments += 1
                continue
            }
            let count = pages.count
            let start = min(max(requestedStart, 1), count)
            let end = min(max(requestedEnd ?? count, start), count)
            let states = try pages[(start - 1) ..< end].map { try handwriting($0, configuration) }
            let label = states.lazy.compactMap { state -> String? in
                if case .recognized(let r) = state, r.status == .text { return r.label }
                return nil
            }.first
            if let configuration, let label { block += Self.recognizerLine(configuration, label: label) + "\n" }
            var nextPage: Int?
            for pageNo in start ... end {
                let body = Self.pageBody(pages[pageNo - 1], states[pageNo - start], documentID: document.id)
                // Always return at least one page, even when it alone is over the budget.
                if returnedPages > 0, body.count > budget {
                    nextPage = pageNo
                    break
                }
                budget -= body.count
                returnedPages += 1
                block += "\n--- Page \(pageNo) of \(count) ---\n\n\(body)\n"
            }
            if let nextPage {
                block +=
                    "\n--- Stopped before page \(nextPage) of \(count) to keep this result short. "
                    + "Call fetch_document with id \(document.id) and pages {\"start\": \(nextPage), \"end\": \(end)} "
                    + "for the rest. ---\n"
            }
            blocks.append(block)
            returnedDocuments += 1
            if nextPage != nil { break }
        }
        let skipped = documents.dropFirst(returnedDocuments)
        if !skipped.isEmpty {
            blocks.append(
                "Not returned, because the result reached its size limit: "
                    + skipped.map(\.id).joined(separator: ", ") + ". Fetch them in another call."
            )
        }
        return .init(content: blocks.map { .text(text: $0, annotations: nil, _meta: nil) })
    }

    // MARK: fetch_page_image

    func fetchPageImage(_ arguments: [String: Value]) throws -> CallTool.Result {
        guard let id = Self.string(arguments, "id") else { throw ToolError("id is required.") }
        let document = try loader.document(id)
        guard let pageNo = try Self.integer(arguments, "page_no") else { throw ToolError("page_no is required.") }
        let page = try loader.page(document, pageNo)
        let (scene, source) = try loader.rendering(document, page)
        let image = try PageRenderer.render(scene, maxWidth: Self.imageWidth, maxHeight: Self.imageHeight)
        var note = "\(document.name), page \(pageNo) of \(document.pageCount). "
        note += "PNG, \(image.width) x \(image.height) pixels, \(image.png.count) bytes. "
        note += source.note(date: Self.date) + " "
        note += "Copied from \(Self.sourceName(document.source)). " + mirrorSentence(try library.status())
        let screens = scene.height / scene.screenHeight
        if screens > 1.05 {
            note += String(
                format: " The page is %.1f screens long, so the image is small; fetch_page_chunks shows it in strips.",
                screens
            )
        }
        return .init(content: [
            .image(data: image.png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
            .text(text: note, annotations: nil, _meta: nil),
        ])
    }

    // MARK: fetch_page_chunks

    struct ChunkEntry: Codable {
        let idx: Int
        /// The strip's top and bottom as fractions of the page height.
        let top: Double
        let bottom: Double
        let width: Int
        let height: Int
    }

    struct ChunksResult: Codable {
        let id: String
        let page_no: Int
        let chunk_count: Int
        let chunks: [ChunkEntry]
        let next_idx: Int?
        /// `tablet` when the strips come from the tablet's own PDF export, and `repossess` otherwise.
        let rendering: String
        let rendering_note: String
        let mirror: MirrorEntry?
    }

    func fetchPageChunks(_ arguments: [String: Value]) throws -> CallTool.Result {
        guard let id = Self.string(arguments, "id") else { throw ToolError("id is required.") }
        let document = try loader.document(id)
        guard let pageNo = try Self.integer(arguments, "page_no") else { throw ToolError("page_no is required.") }
        let page = try loader.page(document, pageNo)
        let (scene, source) = try loader.rendering(document, page)
        let stripHeight = scene.screenHeight / CGFloat(Self.chunksPerScreen)
        let count = max(Int((scene.height / stripHeight).rounded(.up)), 1)
        let afterIdx = max(try Self.integer(arguments, "after_idx") ?? 0, 0)
        guard afterIdx < count else {
            throw ToolError("The page has \(count) strips; after_idx \(afterIdx) leaves none.")
        }
        var content: [Tool.Content] = []
        var chunks: [ChunkEntry] = []
        let last = min(afterIdx + Self.chunksPerCall, count)
        for idx in (afterIdx + 1) ... last {
            let top = max(CGFloat(idx - 1) * stripHeight - Self.chunkOverlap, 0)
            let bottom = min(CGFloat(idx) * stripHeight + Self.chunkOverlap, scene.height)
            let image = try PageRenderer.render(
                scene,
                top: top,
                bottom: bottom,
                maxWidth: Self.chunkWidth,
                maxHeight: .greatestFiniteMagnitude
            )
            content.append(.text(text: "Strip \(idx) of \(count):", annotations: nil, _meta: nil))
            content.append(
                .image(data: image.png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil)
            )
            chunks.append(
                ChunkEntry(
                    idx: idx,
                    top: Double(top / scene.height),
                    bottom: Double(bottom / scene.height),
                    width: image.width,
                    height: image.height
                )
            )
        }
        let result = ChunksResult(
            id: document.id,
            page_no: pageNo,
            chunk_count: count,
            chunks: chunks,
            next_idx: last < count ? last : nil,
            rendering: source.name,
            rendering_note: source.note(date: Self.date),
            mirror: try mirror()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        content.append(
            .text(text: String(decoding: try encoder.encode(result), as: UTF8.self), annotations: nil, _meta: nil)
        )
        return try .init(content: content, structuredContent: result)
    }

    // MARK: refresh_documents

    func refreshDocuments(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let raw = Self.string(arguments, "source") ?? "auto"
        guard let source = RefreshSource(rawValue: raw) else {
            throw ToolError("source must be auto, usb, or cloud.")
        }
        let reports: [RefreshReport]
        do {
            reports = try await refresh(source)
        } catch {
            throw ToolError("The refresh failed: \(error)")
        }
        var out = ""
        for report in reports {
            let name = report.source == .usb ? (report.byApp ? "USB by rePossess.app" : "USB") : "the cloud"
            out += "Refreshed from \(name) in \(String(format: "%.1f", report.seconds)) seconds: "
            out += "\(report.listed) documents, \(report.downloaded) downloaded, \(report.unchanged) unchanged, "
            out += "\(report.removed) removed, \(report.requests) requests.\n"
            if report.keptNewer > 0 {
                out += "\(report.keptNewer) documents were kept as they were, "
                out += "because the mirror's copy is newer than the cloud's.\n"
            }
            if !report.failed.isEmpty {
                out += "\(report.failed.count) documents could not be read.\n"
            }
            if report.exportsDownloaded > 0 || report.exportsFailed > 0 {
                out += "The tablet's PDF exports: \(report.exportsDownloaded) downloaded"
                out += report.exportsFailed > 0 ? ", \(report.exportsFailed) not available.\n" : ".\n"
            }
            if let stopped = report.stoppedBy { out += "The refresh stopped early: \(stopped)\n" }
            for push in report.pushes {
                let result = PushResult(push)
                out += "Push \"\(push.title)\" (\(push.id)): \(result.status). \(result.message)\n"
            }
        }
        return Self.text(out)
    }

    // MARK: push_markdown and push_file

    func pushMarkdown(_ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let pusher else { throw ToolError("This server does not send documents to the tablet.") }
        guard let title = Self.string(arguments, "title") else { throw ToolError("title is required.") }
        guard let markdown = Self.string(arguments, "markdown") else { throw ToolError("markdown is required.") }
        let paginate = arguments["paginate"]?.boolValue ?? false
        do {
            return try Self.json(try await pusher.pushMarkdown(title: title, markdown: markdown, paginate: paginate))
        } catch let error as NotebookError {
            throw ToolError("Nothing was sent: \(error).")
        } catch let error as PushError {
            throw ToolError("Nothing was sent: \(error).")
        }
    }

    func pushFile(_ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let pusher else { throw ToolError("This server does not send documents to the tablet.") }
        let path = Self.string(arguments, "path")
        let url = Self.string(arguments, "url")
        guard (path == nil) != (url == nil) else { throw ToolError("Give exactly one of path or url.") }
        do {
            return try Self.json(
                try await pusher.pushFile(path: path, url: url, title: Self.string(arguments, "title"))
            )
        } catch let error as NotebookError {
            throw ToolError("Nothing was sent: \(error).")
        } catch let error as PushError {
            throw ToolError("Nothing was sent: \(error).")
        } catch let error as CocoaError {
            throw ToolError("Nothing was sent: the file could not be read (\(error.localizedDescription)).")
        }
    }

    // MARK: status

    struct TransportStatus: Codable {
        let available: Bool
        /// The last refresh from this source that finished.
        let last_success: String?
        /// The error of the last refresh from this source, if it failed after the last success.
        let last_error: String?
        let last_error_at: String?
    }

    struct StatusResult: Codable {
        let library: String
        let documents: Int
        let folders: Int
        let pages: Int
        let usb: TransportStatus
        let cloud: TransportStatus
        let mirror: MirrorEntry?
        /// The pushes in each state: `queued`, `unknown`, `sent`, and `failed`.
        let pushes: [String: Int]
        let recognizer: RecognizerStatus
    }

    func pushCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for (status, count) in try library.pushCounts() {
            let name =
                switch status {
                case .pending: "queued"
                case .sending, .unknown: "unknown"
                case .sent: "sent"
                case .failed: "failed"
                }
            counts[name, default: 0] += count
        }
        return counts
    }

    func status() async throws -> CallTool.Result {
        let status = try library.status()
        func transport(_ source: Source, available: Bool) -> TransportStatus {
            TransportStatus(
                available: available,
                last_success: status.lastRefresh[source].map { Self.date($0) },
                last_error: status.lastError[source],
                last_error_at: status.lastErrorAt[source].map { Self.date($0) }
            )
        }
        return try Self.json(
            StatusResult(
                library: status.root.path,
                documents: status.documents,
                folders: status.folders,
                pages: status.pages,
                usb: transport(.usb, available: usbConnected()),
                cloud: transport(.cloud, available: cloudPaired()),
                mirror: mirror(status),
                pushes: pushCounts(),
                recognizer: await recognizerStatus()
            )
        )
    }
}
