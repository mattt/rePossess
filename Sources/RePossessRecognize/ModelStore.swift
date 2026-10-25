import CryptoKit
import Foundation

/// A model pinned to one revision of a Hugging Face repository, with the size and SHA-256 of each file.
public struct PinnedModel: Sendable {
    public struct File: Sendable, Equatable {
        public var name: String
        public var bytes: Int64
        public var sha256: String
    }

    public var repository: String
    public var revision: String
    public var files: [File]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// The folder name of the repository in the Hugging Face cache, such as `models--org--name`.
    var cacheName: String { "models--" + repository.replacingOccurrences(of: "/", with: "--") }

    /// The URL of a file at the pinned revision.
    func url(_ file: File) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
    }

    /// Spike 5's default: Qwen3-VL 8B Instruct in a 4-bit MLX quantization.
    ///
    /// The hashes were read on 2026-10-25 from the copy that spike 5 downloaded with `hf download`.
    /// The three large files' SHA-256 values are the names of their blobs in the Hugging Face cache,
    /// which are the repository's LFS object IDs,
    /// and every other file's git blob ID matched its blob name.
    /// The repository's README.md and .gitattributes are left out; the model does not read them.
    public static let qwen3VL8B = PinnedModel(
        repository: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
        revision: "defcdea7cc7a4b0858fea563cbbce171d328e457",
        files: [
            File(
                name: "added_tokens.json",
                bytes: 707,
                sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"
            ),
            File(
                name: "chat_template.jinja",
                bytes: 5292,
                sha256: "3636d0f0bd6bef02654cdffdc447b79cb2cef8ab02cc75267345946291a489e4"
            ),
            File(
                name: "chat_template.json",
                bytes: 5499,
                sha256: "5c72a170d2a4a1a3bc5adad2e689ae28138a9700e5b8c96c0266331e86c0acce"
            ),
            File(
                name: "config.json",
                bytes: 7140,
                sha256: "cb750ae5688f3df07b110381d3dd54a7f2bfa9ec5175ae11e41305b516f3059a"
            ),
            File(
                name: "generation_config.json",
                bytes: 269,
                sha256: "8469742d1fce0de951c8909b26a2c0c0d8490837ce476efb114da9e0cefc4d44"
            ),
            File(
                name: "merges.txt",
                bytes: 1_671_853,
                sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
            ),
            File(
                name: "model-00001-of-00002.safetensors",
                bytes: 5_353_972_197,
                sha256: "7c637158b2203e321d83596d3661f33b7b98a72beddfaaaa0eddc512acbdd1fb"
            ),
            File(
                name: "model-00002-of-00002.safetensors",
                bytes: 406_693_049,
                sha256: "77190cd1dcf244522869bf923558340112b26d7db2ef3692f88407dd9b33c25d"
            ),
            File(
                name: "model.safetensors.index.json",
                bytes: 67759,
                sha256: "520b2e05079402e9468a8701d03d1154d14b2599593afb6effa7fb60c1bff070"
            ),
            File(
                name: "preprocessor_config.json",
                bytes: 782,
                sha256: "93585062a80db5e8ca038efc7726a3e6411d9db948472d81d63c6303993be8c5"
            ),
            File(
                name: "special_tokens_map.json",
                bytes: 613,
                sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"
            ),
            File(
                name: "tokenizer.json",
                bytes: 11_422_654,
                sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
            ),
            File(
                name: "tokenizer_config.json",
                bytes: 5445,
                sha256: "81ec7bb9530159b326c0bef1d0b6c33d392090524014ea3f0123a3c1eb9c2af5"
            ),
            File(
                name: "video_preprocessor_config.json",
                bytes: 817,
                sha256: "59c5c9eb52182eb14c06ffb10ca9effd29adce5f238a95de23ca14a38dbd2cb1"
            ),
            File(
                name: "vocab.json",
                bytes: 2_776_833,
                sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
            ),
        ]
    )
}

/// Fetches part of a file over HTTP, for the model download.
///
/// The live fetcher is ``URLSessionRangeFetcher``; tests use a fake.
public protocol RangeFetcher: Sendable {
    /// Writes the bytes of `url` from `offset` to the end of `file`, calling `progress` with each chunk's size.
    /// When the server ignores the range and sends the whole file, the fetcher empties `file` first.
    func fetch(_ url: URL, from offset: Int64, into file: FileHandle, progress: @escaping @Sendable (Int64) -> Void)
        async throws
}

/// Where the pinned model lives, and its download.
///
/// rePossess looks for the model in its own folder in the library, `models/<repository>/<revision>/`,
/// and then in the Hugging Face cache, at the pinned revision's snapshot,
/// so that a copy from `hf download` is used where it is, without the network.
/// A folder counts only when every file is there with its pinned size;
/// ``verify(_:)`` checks the hashes.
public struct ModelStore: Sendable {
    public var model: PinnedModel
    public var libraryRoot: URL
    public var environment: [String: String]

    public init(
        model: PinnedModel = .qwen3VL8B,
        libraryRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.model = model
        self.libraryRoot = libraryRoot
        self.environment = environment
    }

    /// rePossess's own copy: `models/<org>--<name>/<revision>/` in the library.
    public var libraryFolder: URL {
        libraryRoot.appending(path: "models", directoryHint: .isDirectory)
            .appending(path: model.repository.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
            .appending(path: model.revision, directoryHint: .isDirectory)
    }

    /// The Hugging Face cache's snapshot of the pinned revision,
    /// under `HF_HUB_CACHE`, `HF_HOME/hub`, or `~/.cache/huggingface/hub`.
    public var huggingFaceSnapshot: URL {
        let hub: URL
        if let cache = environment["HF_HUB_CACHE"], !cache.isEmpty {
            hub = URL(filePath: (cache as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        } else if let home = environment["HF_HOME"], !home.isEmpty {
            hub = URL(filePath: (home as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                .appending(path: "hub", directoryHint: .isDirectory)
        } else {
            hub = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory)
        }
        return hub.appending(path: model.cacheName, directoryHint: .isDirectory)
            .appending(path: "snapshots", directoryHint: .isDirectory)
            .appending(path: model.revision, directoryHint: .isDirectory)
    }

    /// Whether every file is in the folder with its pinned size.
    public func isComplete(_ folder: URL) -> Bool {
        model.files.allSatisfy { size(folder.appending(path: $0.name)) == $0.bytes }
    }

    /// The first complete copy: the library's, then the Hugging Face cache's.
    public func locate() -> URL? {
        [libraryFolder, huggingFaceSnapshot].first(where: isComplete)
    }

    func size(_ url: URL) -> Int64? {
        // Follow the Hugging Face cache's symbolic links to the blobs.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// The SHA-256 of a file, in hexadecimal, read in chunks.
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url.resolvingSymlinksInPath())
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks every file's size and hash.
    /// - Returns: The names of the files that are missing or differ; empty when the copy is good.
    public func verify(_ folder: URL) throws -> [String] {
        try model.files.compactMap { file in
            let url = folder.appending(path: file.name)
            guard size(url) == file.bytes else { return file.name }
            return try Self.sha256(url) == file.sha256 ? nil : file.name
        }
    }

    /// Downloads the pinned model into ``libraryFolder``, file by file, and checks each file's hash.
    ///
    /// A file that is already there with its size and hash is kept.
    /// A partial file, `<name>.part`, continues from where it stopped
    /// when the server honors the range; otherwise it starts again.
    /// A file whose hash differs is deleted, and the download stops with an error.
    /// Call it only when the owner starts the download.
    /// - Parameters:
    ///   - progress: Receives a line at each file and at about every 5 percent.
    ///   - bytes: Receives the bytes that are on the Mac and the model's total, for a progress bar.
    public func download(
        fetcher: any RangeFetcher = URLSessionRangeFetcher(),
        progress: @escaping @Sendable (String) -> Void,
        bytes: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        let folder = libraryFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = model.totalBytes
        var done: Int64 = 0
        for file in model.files {
            let target = folder.appending(path: file.name)
            if size(target) == file.bytes, try Self.sha256(target) == file.sha256 {
                done += file.bytes
                progress("\(file.name): already here")
                bytes(done, total)
                continue
            }
            try? FileManager.default.removeItem(at: target)
            let part = folder.appending(path: file.name + ".part")
            if !FileManager.default.fileExists(atPath: part.path) {
                FileManager.default.createFile(atPath: part.path, contents: nil)
            }
            var offset = size(part) ?? 0
            if offset > file.bytes {
                try Data().write(to: part)
                offset = 0
            }
            if offset < file.bytes {
                let handle = try FileHandle(forWritingTo: part)
                try handle.seekToEnd()
                let start = done + offset
                let reporter = ProgressReporter(
                    name: file.name,
                    total: total,
                    start: start,
                    report: progress,
                    bytes: bytes
                )
                if offset > 0 { progress("\(file.name): continuing at \(offset) of \(file.bytes) bytes") }
                do {
                    try await fetcher.fetch(model.url(file), from: offset, into: handle) { reporter.add($0) }
                } catch {
                    try? handle.close()
                    throw RecognizerError.download(
                        "\(file.name) stopped at \(size(part) ?? 0) of \(file.bytes) bytes (\(error)); "
                            + "run the download again to continue."
                    )
                }
                try handle.close()
            }
            guard size(part) == file.bytes else {
                throw RecognizerError.download(
                    "\(file.name) has \(size(part) ?? 0) bytes, not \(file.bytes); run the download again to continue."
                )
            }
            guard try Self.sha256(part) == file.sha256 else {
                try? FileManager.default.removeItem(at: part)
                throw RecognizerError.download(
                    "\(file.name) does not match its pinned SHA-256, so it was deleted; run the download again."
                )
            }
            try FileManager.default.moveItem(at: part, to: target)
            done += file.bytes
            progress("\(file.name): checked")
            bytes(done, total)
        }
        return folder
    }
}

/// Reports a download's progress in steps of about 5 percent.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let name: String
    private let total: Int64
    private var received: Int64
    private var lastPercent: Int
    private var lastBytes: Int64 = 0
    private let report: @Sendable (String) -> Void
    private let bytes: @Sendable (Int64, Int64) -> Void

    init(
        name: String,
        total: Int64,
        start: Int64,
        report: @escaping @Sendable (String) -> Void,
        bytes: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) {
        self.name = name
        self.total = max(total, 1)
        self.received = start
        self.lastPercent = Int(start * 100 / max(total, 1))
        self.report = report
        self.bytes = bytes
    }

    func add(_ count: Int64) {
        let (line, now): (String?, Int64?) = lock.withLock {
            received += count
            // The byte count goes out at about every 0.2 percent, so that a progress bar moves smoothly.
            var now: Int64? = nil
            if received - lastBytes >= total / 500 || received >= total {
                lastBytes = received
                now = received
            }
            let percent = Int(received * 100 / total)
            guard percent >= lastPercent + 5 else { return (nil, now) }
            lastPercent = percent
            let line = String(
                format: "%d%%: %.2f of %.2f GB (%@)",
                percent,
                Double(received) / 1e9,
                Double(total) / 1e9,
                name
            )
            return (line, now)
        }
        if let now { bytes(now, total) }
        if let line { report(line) }
    }
}

/// Fetches ranges with `URLSession`, writing each chunk to the file as it arrives.
public struct URLSessionRangeFetcher: RangeFetcher {
    public init() {}

    public func fetch(
        _ url: URL,
        from offset: Int64,
        into file: FileHandle,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let delegate = ChunkWriter(file: file, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}

/// Writes a data task's chunks to a file.
final class ChunkWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let file: FileHandle
    let progress: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<Void, any Error>?
    private var failure: (any Error)?

    init(file: FileHandle, progress: @escaping @Sendable (Int64) -> Void) {
        self.file = file
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            failure = RecognizerError.download(
                "\(response.url?.absoluteString ?? "The server") answered HTTP \(status)"
            )
            completionHandler(.cancel)
            return
        }
        let ranged = dataTask.originalRequest?.value(forHTTPHeaderField: "Range") != nil
        if ranged, status != 206 {
            // The server ignored the range: write the whole file from its start.
            do {
                try file.truncate(atOffset: 0)
            } catch {
                failure = error
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try file.write(contentsOf: data)
            progress(Int64(data.count))
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
