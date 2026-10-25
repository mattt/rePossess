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
        return PageScene(pageBytes: bytes ?? nil, pdfPage: pdfPage)
    }
}
