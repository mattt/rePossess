import CoreGraphics
import Foundation
import RePossessCloud
import RePossessFormat
import RePossessLibrary
import RePossessMCP
import RePossessRender
import RePossessUSB

let version = "0.1.0"

let usage = """
    usage: repossess <command> [options]

    Commands:
      refresh [--usb | --cloud]   Refresh the mirror from the tablet. Without a flag, use USB
                                  when the tablet is connected by cable, and the cloud otherwise.
      status                      Show the library, and each source's last success and last error.
      list                        List the documents: path, pages, text status, modified, and ID.
      mcp                         Serve the tools over MCP on standard input and output.

    Commands that add documents to the tablet (each push makes a new document; none replaces one):
      push-markdown <file.md | -> --title <title> [--paginate] [--usb | --cloud] [--out <file.rmdoc>]
                                  Send Markdown as a notebook. --paginate starts a page at each ## heading.
                                  --out writes the notebook to a file and sends nothing.
      push-file <path | https-url> [--title <title>] [--usb | --cloud]
                                  Send a PDF or EPUB.
      pushes                      List the queue of pushes and what happened to each.
      drop-push <id>              Remove a push that has not been sent.

    Commands for the cloud:
      pair                        Pair with your reMarkable account. Reads a one-time code from
                                  standard input; get one from \(CloudHosts.connectPage.absoluteString).
      unpair                      Delete the device token from the login keychain.
      check-token                 Read the device token from the login keychain, without sending it
                                  anywhere, so that macOS can ask once for permission.

    Commands for checking the renderer:
      render <id> <page> --out <file.png> [--scale <pixels per page pixel>]
      export-pdf <id> --out <file.pdf>
                                  Download the PDF that the tablet renders, over USB.
      layout <id> <page>          Print the laid-out text lines and stroke groups as JSON.

    Options:
      --library <folder>          The library folder. The default is $REPOSSESS_LIBRARY,
                                  or ~/Library/Application Support/rePossess.
      --rmdoc <file>              For render and layout: read this rmdoc instead of the library.
    """

struct UsageError: Error, CustomStringConvertible {
    var description: String
    init(_ message: String) { description = message }
}

/// The parsed command line.
struct Arguments {
    var command: String
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["--library", "--out", "--scale", "--rmdoc", "--title"]

    init(_ arguments: [String]) throws {
        guard let first = arguments.first else { throw UsageError(usage) }
        command = first
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            if Self.valued.contains(argument) {
                guard let value = rest.popFirst() else { throw UsageError("\(argument) needs a value") }
                options[argument] = value
            } else if argument.hasPrefix("--") {
                flags.insert(argument)
            } else {
                positional.append(argument)
            }
        }
    }
}

func libraryRoot(_ arguments: Arguments) -> URL {
    if let path = arguments.options["--library"] ?? ProcessInfo.processInfo.environment["REPOSSESS_LIBRARY"] {
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }
    return Library.defaultRoot
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func describe(_ result: PushResult) -> String {
    var lines = [
        "Push: \(result.push_id)", "Title: \(result.title)", "Kind: \(result.kind)", "Status: \(result.status)",
    ]
    if let via = result.via { lines.append("Via: \(via == "usb" ? "USB" : "cloud")") }
    if let id = result.tablet_id { lines.append("Document ID: \(id)") }
    if let pages = result.pages { lines.append("Pages: \(pages)") }
    lines += ["Bytes: \(result.bytes)", result.message]
    return lines.joined(separator: "\n")
}

/// The paths for a push command: both by availability, or the one that a flag names.
func pushPaths(_ arguments: Arguments, session: CloudSession) throws -> @Sendable () -> PushPaths {
    let usb = arguments.flags.contains("--usb")
    let cloud = arguments.flags.contains("--cloud")
    guard !(usb && cloud) else { throw UsageError("give --usb or --cloud, not both") }
    if usb {
        guard USBNetwork.isPresent() else { throw UsageError("the tablet is not connected by USB") }
        return { PushPaths(usb: { USBClient() }, cloud: nil) }
    }
    if cloud {
        guard DeviceTokenKeychain.exists() else { throw UsageError("rePossess is not paired; run `repossess pair`") }
        return { PushPaths(usb: nil, cloud: session) }
    }
    return Pusher.availablePaths(session: session)
}

func describe(_ report: RefreshReport) -> String {
    var lines = [
        "Source: \(report.source == .usb ? "USB" : "cloud")",
        "Documents listed: \(report.listed)",
        "Downloaded: \(report.downloaded)",
        "Unchanged: \(report.unchanged)",
        "Removed: \(report.removed)",
    ]
    if report.source == .cloud {
        lines += [
            "Kept because the mirror's copy is newer: \(report.keptNewer)",
            "Files downloaded: \(report.filesDownloaded)",
            "Files reused from the mirror: \(report.filesReused) (\(report.bytesReused) bytes)",
        ]
    }
    lines += [
        "Requests: \(report.requests)",
        "Bytes received: \(report.bytes)",
    ]
    if report.retries > 0 || report.waits > 0 {
        lines.append("Retries: \(report.retries); rate-limit waits: \(report.waits)")
    }
    lines.append(String(format: "Seconds: %.2f", report.seconds))
    if !report.failed.isEmpty {
        lines.append("Failed: \(report.failed.count)")
        lines += report.failed.map { "  \($0)" }
    }
    if report.exportsDownloaded > 0 || report.exportsFailed > 0 {
        lines.append(
            "Tablet PDF exports: \(report.exportsDownloaded) downloaded, \(report.exportsFailed) not available"
        )
    }
    if let stopped = report.stoppedBy { lines.append("Stopped: \(stopped)") }
    for push in report.pushes {
        lines.append(
            "Push \(push.id) \"\(push.title)\": \(push.status.rawValue)\(push.via.map { " via \($0.rawValue)" } ?? "")"
        )
    }
    return lines.joined(separator: "\n")
}

/// A page for `render` and `layout`: from the library, or from an rmdoc file.
func loadScene(_ arguments: Arguments) throws -> PageScene {
    guard arguments.positional.count == 2, let pageNo = Int(arguments.positional[1]) else {
        throw UsageError("give a document ID and a page number")
    }
    let id = arguments.positional[0]
    let library: Library
    if let rmdoc = arguments.options["--rmdoc"] {
        let root = FileManager.default.temporaryDirectory.appending(path: "repossess-\(UUID().uuidString)")
        library = try Library(root: root)
        let archive = try RmdocArchive(data: Data(contentsOf: URL(filePath: rmdoc)))
        let folder = try archive.unpack(into: library.root.appending(path: "documents/\(id)"), as: id)
        try library.importForChecking(folder)
    } else {
        library = try Library(root: libraryRoot(arguments))
    }
    let loader = PageLoader(library: library)
    let document = try loader.document(id)
    return try loader.scene(document, try loader.page(document, pageNo))
}

@main
struct Repossess {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as UsageError {
            printError(error.description)
            exit(64)
        } catch {
            printError("repossess: \(error)")
            exit(1)
        }
    }

    static func run(_ argv: [String]) async throws {
        let arguments = try Arguments(argv)
        switch arguments.command {
        case "refresh":
            let usb = arguments.flags.contains("--usb")
            let cloud = arguments.flags.contains("--cloud")
            guard !(usb && cloud) else { throw UsageError("give --usb or --cloud, not both") }
            let library = try Library(root: libraryRoot(arguments))
            let session = CloudSession()
            let reports = try await refreshLibrary(
                library,
                usb ? .usb : (cloud ? .cloud : .auto),
                session: session,
                pushes: Pusher.availablePaths(session: session)(),
                progress: { printError($0) }
            )
            print(reports.map(describe).joined(separator: "\n\n"))
            if reports.contains(where: { $0.stoppedBy != nil }) { exit(2) }

        case "status":
            let library = try Library(root: libraryRoot(arguments))
            let status = try library.status()
            print("Library: \(status.root.path)")
            print("Documents: \(status.documents) in \(status.folders) folders, \(status.pages) pages")
            for source in [Source.usb, .cloud] {
                let name = source == .usb ? "USB" : "Cloud"
                let when = status.lastRefresh[source].map { $0.formatted(.iso8601) } ?? "never"
                print("\(name) last success: \(when)")
                if let error = status.lastError[source] {
                    let at = status.lastErrorAt[source].map { $0.formatted(.iso8601) } ?? "time unknown"
                    print("\(name) last error (\(at)): \(error)")
                } else {
                    print("\(name) last error: none since the last success")
                }
            }
            print("USB network present: \(USBNetwork.isPresent() ? "yes" : "no")")
            let service = DeviceTokenKeychain.pairedService()
            print("Cloud device token in the Keychain: \(service.map { "yes, under \"\($0)\"" } ?? "no")")
            let counts = try library.pushCounts()
            let queue = [PushStatus.pending, .unknown, .failed, .sent].compactMap { status in
                counts[status].map { "\($0) \(status.rawValue)" }
            }
            print("Pushes: \(queue.isEmpty ? "none" : queue.joined(separator: ", "))")

        case "list":
            let library = try Library(root: libraryRoot(arguments))
            for document in try library.documents() {
                let modified = document.modified.map { $0.formatted(.iso8601) } ?? ""
                print(
                    [
                        document.path, document.fileType ?? "notebook", "\(document.pageCount)",
                        document.contentStatus.rawValue, modified, document.id,
                    ]
                    .joined(separator: "\t")
                )
            }

        case "mcp":
            let library = try Library(root: libraryRoot(arguments))
            // No one watches the server, so it waits at most 20 seconds for a Keychain dialog.
            let session = CloudSession(tokenTimeout: .seconds(20))
            let paths = Pusher.availablePaths(session: session)
            let tools = RePossessTools(
                library: library,
                refresh: { source in
                    try await refreshLibrary(
                        library,
                        source,
                        session: session,
                        pushes: paths(),
                        progress: { printError($0) }
                    )
                },
                pusher: Pusher(library: library, paths: paths, progress: { printError($0) })
            )
            try await serveMCP(tools: tools, version: version)

        case "push-markdown":
            guard arguments.positional.count == 1, let title = arguments.options["--title"] else {
                throw UsageError("push-markdown needs a Markdown file, or - for standard input, and --title")
            }
            let source = arguments.positional[0]
            let markdown =
                source == "-"
                ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                : try String(contentsOf: URL(filePath: (source as NSString).expandingTildeInPath), encoding: .utf8)
            let paginate = arguments.flags.contains("--paginate")
            if let out = arguments.options["--out"] {
                let notebook = try MarkdownNotebook(title: title, markdown: markdown, paginate: paginate)
                try notebook.rmdoc.write(to: URL(filePath: out))
                print(
                    "Wrote \(out): \(notebook.pageCount) pages, \(notebook.paragraphCount) paragraphs. Nothing was sent."
                )
                return
            }
            let library = try Library(root: libraryRoot(arguments))
            let session = CloudSession()
            let pusher = Pusher(
                library: library,
                paths: try pushPaths(arguments, session: session),
                progress: { printError($0) }
            )
            print(describe(try await pusher.pushMarkdown(title: title, markdown: markdown, paginate: paginate)))

        case "push-file":
            guard arguments.positional.count == 1 else { throw UsageError("push-file needs a path or an https URL") }
            let target = arguments.positional[0]
            let isURL = target.lowercased().hasPrefix("https://") || target.lowercased().hasPrefix("http://")
            let library = try Library(root: libraryRoot(arguments))
            let session = CloudSession()
            let pusher = Pusher(
                library: library,
                paths: try pushPaths(arguments, session: session),
                progress: { printError($0) }
            )
            let result = try await pusher.pushFile(
                path: isURL ? nil : target,
                url: isURL ? target : nil,
                title: arguments.options["--title"]
            )
            print(describe(result))

        case "pushes":
            let library = try Library(root: libraryRoot(arguments))
            for push in try library.pushes() {
                print(
                    [
                        push.id, push.status.rawValue, push.via?.rawValue ?? "-", push.kind.rawValue,
                        push.created.formatted(.iso8601), push.tabletID ?? "-", push.title, push.error ?? "",
                    ]
                    .joined(separator: "\t")
                )
            }

        case "drop-push":
            guard arguments.positional.count == 1 else { throw UsageError("drop-push needs a push ID") }
            let library = try Library(root: libraryRoot(arguments))
            let dropped = try library.dropPush(id: arguments.positional[0])
            print("Dropped \(dropped.id) \"\(dropped.title)\" (\(dropped.status.rawValue)).")
            if dropped.status == .unknown {
                print("Its last send got no answer, so it may be on the tablet. Look for \"\(dropped.title)\" there.")
            }

        case "pair":
            printError("Paste the one-time code from \(CloudHosts.connectPage.absoluteString) and press Return:")
            guard let code = readLine(strippingNewline: true) else { throw UsageError("no code on standard input") }
            let result = try await Pairing().pair(code: code)
            print(
                "Paired as a desktop-macos device. The device token is in the login keychain under \"\(result.service)\"."
            )
            if let older = result.olderService {
                print(
                    "The older item \"\(older)\" is still in the login keychain, and rePossess no longer reads it."
                        + " Its device stays on your account until you remove it on my.remarkable.com."
                )
            }

        case "unpair":
            print(Pairing.unpairMessage(deleted: try Pairing().unpair()))

        case "check-token":
            // Reads the secret, so macOS may ask for permission; the token is never printed or sent.
            let (token, service) = try DeviceTokenKeychain.read(from: SystemKeychain())
            let claims = try? TokenClaims(jwt: token)
            print("Read the device token from the login keychain item \"\(service)\".")
            if let description = claims?.deviceDescription { print("Device type: \(description)") }

        case "render":
            guard let out = arguments.options["--out"] else { throw UsageError("render needs --out") }
            let scene = try loadScene(arguments)
            let image: RenderedImage
            if let scale = arguments.options["--scale"].flatMap(Double.init) {
                image = try PageRenderer.render(
                    scene,
                    maxWidth: scene.width * scale,
                    maxHeight: scene.height * scale
                )
            } else {
                image = try PageRenderer.render(
                    scene,
                    maxWidth: RePossessTools.imageWidth,
                    maxHeight: RePossessTools.imageHeight
                )
            }
            try image.png.write(to: URL(filePath: out))
            print("\(image.width) x \(image.height) pixels, \(image.png.count) bytes")
            for warning in scene.warnings { printError("warning: \(warning)") }

        case "export-pdf":
            guard let out = arguments.options["--out"], arguments.positional.count == 1 else {
                throw UsageError("export-pdf needs a document ID and --out")
            }
            let start = Date()
            let data = try await USBClient().pdf(id: arguments.positional[0])
            try data.write(to: URL(filePath: out))
            print(String(format: "%d bytes in %.2f seconds", data.count, Date().timeIntervalSince(start)))

        case "layout":
            let scene = try loadScene(arguments)
            var lines: [[String: Any]] = []
            for line in scene.layout?.lines ?? [] {
                lines.append([
                    "text": line.plain, "x": Double(line.x), "baseline": Double(line.baseline),
                    "style": line.style.name,
                ])
            }
            let groups = scene.strokeGroups.map { group -> [String: Any] in
                [
                    "x": Double(group.bounds.minX), "y": Double(group.bounds.minY),
                    "width": Double(group.bounds.width), "height": Double(group.bounds.height),
                    "anchored": group.anchored, "strokes": group.strokes,
                ]
            }
            let object: [String: Any] = [
                "width": Double(scene.width), "height": Double(scene.height), "lines": lines, "groups": groups,
                "warnings": scene.warnings,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))

        case "help", "--help", "-h":
            print(usage)

        default:
            throw UsageError("unknown command \(arguments.command)\n\n\(usage)")
        }
    }
}
