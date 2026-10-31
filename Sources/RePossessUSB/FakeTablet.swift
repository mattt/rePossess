import Foundation

/// An in-memory stand-in for the tablet's USB web interface, for tests.
///
/// It is internal; tests reach it with `@testable import`.
/// It serves the listing, both downloads, and the upload, and records every path it was asked for.
/// When `hang` is set, every request times out, as the Paper Pure's interface did
/// after a thumbnail or search request.
/// An upload adds a document with a new ID at the top level, as the Paper Pure does,
/// and `uploadBehavior` can lose the answer before or after the tablet adds it.
actor FakeTablet: USBTransport {
    /// What the next uploads do.
    enum UploadBehavior: Sendable {
        /// Add the document and answer 201.
        case accept
        /// Add the document, then time out.
        case acceptThenTimeOut
        /// Time out without adding the document.
        case timeOut
        /// Answer with a status and add nothing.
        case status(Int)
    }

    /// One upload that the fake received.
    struct Upload: Sendable {
        var fileName: String
        var contentType: String
        var data: Data
    }

    var items: [USBItem] = []
    var uploadBehavior: UploadBehavior = .accept
    private(set) var uploads: [Upload] = []
    /// The name that an upload gets; by default the file name without its extension.
    /// Tests that upload rmdoc files read the name from the archive's metadata.
    var nameForUpload: @Sendable (String, Data) -> String = { fileName, _ in
        (fileName as NSString).deletingPathExtension
    }
    /// The time that the tablet writes as `ModifiedClient` for an upload.
    var clock: @Sendable () -> Date = Date.init
    var archives: [String: Data] = [:]
    var pdfs: [String: Data] = [:]
    var hang = false
    private(set) var paths: [String] = []
    private var active = 0
    private(set) var maxConcurrent = 0

    init() {}

    func add(_ item: USBItem, rmdoc: Data? = nil, pdf: Data? = nil) {
        items.removeAll { $0.id == item.id }
        items.append(item)
        if let rmdoc { archives[item.id] = rmdoc }
        if let pdf { pdfs[item.id] = pdf }
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        archives[id] = nil
    }

    func setHang(_ value: Bool) { hang = value }

    func removePDF(id: String) { pdfs[id] = nil }

    func set(uploadBehavior: UploadBehavior) { self.uploadBehavior = uploadBehavior }

    func set(nameForUpload: @escaping @Sendable (String, Data) -> String) { self.nameForUpload = nameForUpload }

    func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws
        -> (status: Int, body: Data)
    {
        let path = url.path()
        paths.append("POST \(path)")
        await Task.yield()
        if hang { throw USBError.timedOut(route: path, seconds: Int(timeout)) }
        guard path == "/upload" else { return (404, Data()) }
        guard let part = Self.filePart(body, contentType: contentType) else { return (400, Data()) }
        uploads.append(part)
        switch uploadBehavior {
        case .timeOut:
            throw USBError.timedOut(route: path, seconds: Int(timeout))
        case .status(let status):
            return (status, Data())
        case .accept, .acceptThenTimeOut:
            let id = UUID().uuidString.lowercased()
            let modified = clock().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            let kind = (part.fileName as NSString).pathExtension
            items.append(
                USBItem(
                    id: id,
                    type: "DocumentType",
                    fileType: kind == "rmdoc" ? "notebook" : kind,
                    modifiedClient: modified,
                    visibleName: nameForUpload(part.fileName, part.data)
                )
            )
            if case .acceptThenTimeOut = uploadBehavior {
                throw USBError.timedOut(route: path, seconds: Int(timeout))
            }
            return (201, Data(#"{"status":"Upload successful"}"#.utf8))
        }
    }

    /// The `file` part of a multipart body.
    static func filePart(_ body: Data, contentType: String) -> Upload? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        let boundary = Data("--\(contentType[range.upperBound...])".utf8)
        let separator = Data("\r\n\r\n".utf8)
        guard body.starts(with: boundary), let headerEnd = body.range(of: separator),
            let end = body.range(of: Data("\r\n".utf8) + boundary + Data("--".utf8), options: .backwards)
        else { return nil }
        let headers = String(decoding: body[body.startIndex ..< headerEnd.lowerBound], as: UTF8.self)
        guard headers.contains("name=\"file\""),
            let name = headers.firstMatch(of: /filename="([^"]*)"/)?.1,
            let type = headers.firstMatch(of: /Content-Type: ([^\r\n]*)/)?.1
        else { return nil }
        return Upload(
            fileName: String(name),
            contentType: String(type),
            data: body[headerEnd.upperBound ..< end.lowerBound]
        )
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let path = url.path()
        paths.append(path)
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        defer { active -= 1 }
        await Task.yield()
        if hang { throw USBError.timedOut(route: path, seconds: Int(timeout)) }
        if path == "/documents/" || path.hasPrefix("/documents/") {
            let folder = path == "/documents/" ? "" : String(path.dropFirst("/documents/".count))
            let listing = items.filter { $0.parent == folder }.map { item -> [String: Any] in
                var entry: [String: Any] = [
                    "ID": item.id, "Type": item.type, "Parent": item.parent,
                    "VisibleName": item.visibleName, "VissibleName": item.visibleName,
                    "Bookmarked": false, "CurrentPage": 0,
                ]
                if let fileType = item.fileType { entry["fileType"] = fileType }
                if let modified = item.modifiedClient { entry["ModifiedClient"] = modified }
                return entry
            }
            return (200, try JSONSerialization.data(withJSONObject: listing))
        }
        let parts = path.split(separator: "/")
        if parts.count == 3, parts[0] == "download" {
            let id = String(parts[1])
            let body = parts[2] == "rmdoc" ? archives[id] : (parts[2] == "pdf" ? pdfs[id] : nil)
            guard let body else { return (404, Data()) }
            return (200, body)
        }
        return (404, Data())
    }
}
