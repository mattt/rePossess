import Foundation

/// An in-memory stand-in for the tablet's USB web interface, for tests.
///
/// It is internal; tests reach it with `@testable import`.
/// It serves the listing and both downloads, and records every path it was asked for.
/// When `hang` is set, every request times out, as the Paper Pure's interface did
/// after a thumbnail or search request in spike 1.
actor FakeTablet: USBTransport {
    var items: [USBItem] = []
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
