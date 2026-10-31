import Foundation

/// One blob to upload with `PUT /sync/v3/files/<hash>`.
public struct PlannedPut: Sendable, Equatable {
    /// The value of `rm-filename`.
    public var fileName: String
    /// The hash in the URL.
    public var hash: String
    /// The bytes to send.
    public var body: Data
}

/// A new document to add to the account: its ID, its name, and its files.
public struct NewDocument: Sendable, Equatable {
    /// What the document holds.
    public enum Kind: String, Sendable, Equatable {
        case pdf
        case epub
        /// A notebook from an rmdoc archive.
        case notebook
    }

    /// The document ID, a lowercase UUID, which rePossess chooses.
    public var documentID: String
    public var visibleName: String
    public var kind: Kind
    /// The files, named as in the sync store: `<id>.content`, `<id>.metadata`, and the rest.
    public var files: [(name: String, data: Data)]

    public static func == (a: NewDocument, b: NewDocument) -> Bool {
        a.documentID == b.documentID && a.visibleName == b.visibleName && a.kind == b.kind
            && a.files.map(\.name) == b.files.map(\.name) && a.files.map(\.data) == b.files.map(\.data)
    }

    /// A PDF or an EPUB at the top level, with the files that rmapi-js writes
    /// (`#putFile`, `src/index.ts` lines 1548-1660):
    /// `.content`, `.metadata`, `.pagedata` with one newline, and the file.
    ///
    /// - Parameters:
    ///   - pageID: The ID of the one placeholder page that rmapi-js says the content must claim.
    public static func file(
        _ kind: Kind,
        visibleName: String,
        data: Data,
        documentID: String,
        pageID: String = UUID().uuidString.lowercased(),
        now: Date = Date()
    ) throws -> NewDocument {
        switch kind {
        case .pdf:
            guard data.starts(with: Data("%PDF-".utf8)) else {
                throw CloudError.invalidUpload("the file does not start with %PDF-")
            }
        case .epub:
            guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
                throw CloudError.invalidUpload("an EPUB is a zip file, and this file is not one")
            }
        case .notebook:
            throw CloudError.invalidUpload("a notebook comes from an rmdoc archive")
        }
        let id = try checkedID(documentID)
        return NewDocument(
            documentID: id,
            visibleName: try checkedName(visibleName),
            kind: kind,
            files: [
                ("\(id).content", try contentJSON(kind: kind, size: data.count, pageID: pageID)),
                ("\(id).metadata", try metadataJSON(visibleName: visibleName, now: now)),
                ("\(id).pagedata", Data("\n".utf8)),
                ("\(id).\(kind.rawValue)", data),
            ]
        )
    }

    /// A notebook from the files of an rmdoc archive, renamed to `documentID`,
    /// as rmapi-js's `putDocumentArchive` uploads an archive (`src/index.ts` lines 1478-1545).
    ///
    /// - Parameters:
    ///   - files: The archive's files, named with the archive's document ID.
    ///   - archiveID: The document ID inside the archive.
    public static func notebook(
        files: [(name: String, data: Data)],
        archiveID: String,
        visibleName: String,
        documentID: String
    ) throws -> NewDocument {
        let id = try checkedID(documentID)
        var renamed: [(name: String, data: Data)] = []
        for file in files {
            guard file.name.hasPrefix(archiveID) else {
                throw CloudError.invalidUpload("the archive's file \(file.name) does not start with \(archiveID)")
            }
            let name = id + file.name.dropFirst(archiveID.count)
            guard !name.contains(".."), !name.hasPrefix("/"), !name.contains(":"), !name.contains("\n") else {
                throw CloudError.invalidUpload("unsafe file name \(file.name)")
            }
            renamed.append((name, file.data))
        }
        for required in ["\(id).content", "\(id).metadata"] where !renamed.contains(where: { $0.name == required }) {
            throw CloudError.invalidUpload("the archive has no \(required.dropFirst(id.count))")
        }
        return NewDocument(
            documentID: id,
            visibleName: try checkedName(visibleName),
            kind: .notebook,
            files: renamed
        )
    }

    static func checkedID(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw CloudError.invalidUpload("the document ID \(id) is not a lowercase UUID")
        }
        return id
    }

    static func checkedName(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("\n") else {
            throw CloudError.invalidUpload("the name is empty or has a newline")
        }
        return name
    }

    /// The `.metadata` file (rmapi-js `src/index.ts` lines 1588-1597).
    static func metadataJSON(visibleName: String, now: Date) throws -> Data {
        let millis = String(Int64((now.timeIntervalSince1970 * 1000).rounded()))
        let object: [String: Any] = [
            "createdTime": millis,
            "lastModified": millis,
            "lastOpened": "0",
            "lastOpenedPage": 0,
            "parent": "",
            "pinned": false,
            "type": "DocumentType",
            "visibleName": visibleName,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The `.content` file of a PDF or an EPUB (rmapi-js `src/index.ts` lines 1598-1627).
    ///
    /// rmapi-js notes that it must claim one page and give that page an ID.
    static func contentJSON(kind: Kind, size: Int, pageID: String) throws -> Data {
        let object: [String: Any] = [
            "coverPageNumber": -1,
            "documentMetadata": [String: Any](),
            "extraMetadata": [String: Any](),
            "fileType": kind.rawValue,
            "fontName": "",
            "formatVersion": 1,
            "lineHeight": -1,
            "margins": 125,
            "orientation": "portrait",
            "originalPageCount": 1,
            "pageCount": 1,
            "pageTags": [Any](),
            "pages": [pageID],
            "redirectionPageMap": [0],
            "sizeInBytes": String(size),
            "tags": [Any](),
            "textAlignment": "justify",
            "textScale": 1,
            "zoomMode": "bestFit",
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// The exact writes that add one new document to the account.
public struct UploadPlan: Sendable, Equatable {
    /// The new document's ID.
    public var documentID: String
    /// The document's files.
    public var filePuts: [PlannedPut]
    /// The document's index, `<docid>.docSchema`.
    public var documentIndexPut: PlannedPut
    /// The new root index, `root.docSchema`.
    public var rootIndexPut: PlannedPut
    /// The entry that the new root index adds.
    public var rootEntry: IndexEntry
    /// The schema of the new root index, which is the account's.
    public var rootSchema: SchemaVersion
    /// The hash of the root index that the plan starts from.
    public var baseRootHash: String
    /// The generation that the root update must match.
    public var baseGeneration: Int64
    /// The hash to send in `PUT /sync/v3/root`.
    public var newRootHash: String { rootIndexPut.hash }

    /// Every blob upload, in the order to send them: files, then the document index, then the root index.
    public var blobPuts: [PlannedPut] { filePuts + [documentIndexPut, rootIndexPut] }
}

/// Plans the upload of a new document, without a network.
///
/// The steps follow rmapi-js `#putFile` (`src/index.ts` lines 1548-1660)
/// and `#commit` and `#writeRoot` (lines 734-762):
/// upload the files, upload the document's index in the account's schema,
/// add its entry to the root index, upload the root index,
/// and then put the root hash with the generation that was read.
///
/// rmapi-js always writes the root in schema 4 (line 758).
/// rePossess writes it in the account's schema, as the tablet does:
/// on 2026-10-25 a live run wrote a schema 3 root to the owner's schema 3 account,
/// the server accepted it, and the account stayed on schema 3.
/// A schema 4 root on a schema 3 account reportedly moves the account to schema 4 for good
/// (ddvk/rmapi issue 56), so the planner never writes one.
public enum UploadPlanner {
    /// Plans the upload of a new document to the top level of the library.
    ///
    /// - Parameters:
    ///   - document: The new document.
    ///   - root: The root state that was read.
    ///   - rootIndex: The root index that `root.hash` names.
    public static func plan(_ document: NewDocument, root: RootState, rootIndex: SyncIndex) throws -> UploadPlan {
        let accountSchema: SchemaVersion
        switch root.schemaVersion {
        case 3: accountSchema = .v3
        case 4: accountSchema = .v4
        default:
            throw CloudError.invalidUpload("unknown schema version \(root.schemaVersion.map(String.init) ?? "none")")
        }
        // An empty account has no root index to compare; any other root must be in the account's schema.
        if !root.hash.isEmpty, rootIndex.schema != accountSchema {
            throw CloudError.invalidUpload(
                "the root index is schema \(rootIndex.schema.rawValue), and the account reports \(accountSchema.rawValue)"
            )
        }
        // The new root keeps every existing line. A root that this code would write differently
        // (unsorted, or an info line that does not add up) is a sign of drift: stop.
        if !root.hash.isEmpty,
            rootIndex != SyncIndex.make(id: "root", entries: rootIndex.entries, schema: accountSchema)
        {
            throw CloudError.invalidUpload("the root index is not in the expected form; it would be rewritten")
        }
        let id = document.documentID
        guard !rootIndex.entries.contains(where: { $0.id == id }) else {
            throw CloudError.invalidUpload("the root already has \(id)")
        }

        let filePuts = document.files.map { name, body in
            PlannedPut(fileName: name, hash: ContentHash.sha256Hex(body), body: body)
        }
        let fileEntries = filePuts.map {
            IndexEntry(hash: $0.hash, kind: .file, id: $0.fileName, subfiles: 0, size: $0.body.count)
        }
        let documentIndex = SyncIndex.make(id: id, entries: fileEntries, schema: accountSchema)
        let documentIndexPut = PlannedPut(
            fileName: RequestBuilder.indexFileName(for: id),
            hash: try documentIndex.hash(),
            body: documentIndex.serialized()
        )
        let rootEntry = IndexEntry(
            hash: documentIndexPut.hash,
            kind: accountSchema == .v3 ? .collection : .file,
            id: id,
            subfiles: fileEntries.count,
            size: documentIndex.totalSize
        )
        let newRoot = SyncIndex.make(id: "root", entries: rootIndex.entries + [rootEntry], schema: accountSchema)
        let rootIndexPut = PlannedPut(
            fileName: RequestBuilder.indexFileName(for: "root"),
            hash: try newRoot.hash(),
            body: newRoot.serialized()
        )
        return UploadPlan(
            documentID: id,
            filePuts: filePuts,
            documentIndexPut: documentIndexPut,
            rootIndexPut: rootIndexPut,
            rootEntry: rootEntry,
            rootSchema: accountSchema,
            baseRootHash: root.hash,
            baseGeneration: root.generation
        )
    }
}
