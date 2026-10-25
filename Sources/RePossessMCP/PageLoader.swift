import CoreGraphics
import Foundation
import RePossessFormat
import RePossessLibrary
import RePossessRender

/// An error that a tool reports to the client, with what to call instead.
public struct ToolError: Error, CustomStringConvertible {
    public var message: String

    public init(_ message: String) { self.message = message }

    public var description: String { message }
}

/// Loads pages from the library's mirror for drawing.
public struct PageLoader: Sendable {
    public let library: Library

    public init(library: Library) { self.library = library }

    /// A document by ID, or an error that tells the client how to find one.
    public func document(_ id: String) throws -> LibraryItem {
        guard isValidItemID(id), let item = try library.item(id: id), item.kind == .document else {
            throw ToolError("No document has the id \(id). Call list_documents or search_documents to find one.")
        }
        return item
    }

    /// A page by number, from 1.
    public func page(_ document: LibraryItem, _ pageNo: Int) throws -> LibraryPage {
        let pages = try library.pages(of: document.id)
        guard !pages.isEmpty else {
            throw ToolError("\(document.name) has no pages that rePossess can read.")
        }
        guard (1 ... pages.count).contains(pageNo) else {
            throw ToolError("\(document.name) has pages 1 to \(pages.count); page_no \(pageNo) is out of range.")
        }
        return pages[pageNo - 1]
    }

    /// The page, ready to draw.
    public func scene(_ document: LibraryItem, _ page: LibraryPage) throws -> PageScene {
        let folder = try library.folder(for: document.id)
        let bytes = try? folder.pageBytes(page.pageID)
        var pdfPage: CGPDFPage?
        if let index = page.sourcePageIndex, folder.hasPDF,
            let pdf = CGPDFDocument(folder.pdfURL as CFURL)
        {
            pdfPage = pdf.page(at: index + 1)
        }
        return PageScene(pageBytes: bytes ?? nil, pdfPage: pdfPage) { folder.imageData(page: page.pageID, file: $0) }
    }

    /// The page, ready to draw, from the tablet's PDF export when it is current,
    /// and from rePossess's own rendering otherwise, with the source and the reason.
    public func rendering(_ document: LibraryItem, _ page: LibraryPage) throws -> (scene: PageScene, source: PageSource)
    {
        let state = try library.exportState(for: document)
        if case .current(let export) = state, let pdf = CGPDFDocument(export.url as CFURL),
            let exportPage = pdf.page(at: page.number)
        {
            return (PageScene(exportPage: exportPage, isPDFPage: page.sourcePageIndex != nil), .tablet(export))
        }
        return (try scene(document, page), .rePossess(state))
    }
}

/// Where a page image came from.
public enum PageSource: Sendable {
    /// The tablet's own PDF export, downloaded over USB.
    case tablet(TabletExport)
    /// rePossess's own rendering, with the reason that the export was not used.
    case rePossess(ExportState)

    /// `tablet` or `repossess`, as tool results report it.
    public var name: String {
        if case .tablet = self { return "tablet" }
        return "repossess"
    }

    /// A sentence for a tool result.
    public func note(date: (Date?) -> String) -> String {
        switch self {
        case .tablet(let export):
            return "Drawn from the tablet's own PDF export, downloaded over USB at \(date(export.downloaded))."
        case .rePossess(.notNeeded), .rePossess(.current):
            return "Drawn by rePossess."
        case .rePossess(.missing):
            return "Drawn by rePossess: the typed text uses substitute fonts, so its line breaks can differ "
                + "from the tablet's. A refresh over USB gets the tablet's own PDF of this document."
        case .rePossess(.stale):
            return "Drawn by rePossess, because the document changed after the tablet's PDF export was downloaded: "
                + "the typed text uses substitute fonts, so its line breaks can differ from the tablet's. "
                + "A refresh over USB gets a new export."
        case .rePossess(.pageCountDiffers(let export, let pages)):
            return "Drawn by rePossess, because the tablet's PDF export has \(export.pages) pages "
                + "and the document has \(pages): the typed text uses substitute fonts, "
                + "so its line breaks can differ from the tablet's."
        }
    }
}
