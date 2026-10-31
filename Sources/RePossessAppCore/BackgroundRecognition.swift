import Foundation
import RePossessRecognize

/// Recognizes new handwriting after a refresh, in a separate process.
///
/// The app runs the bundled `repossess recognize`, which reads the pages with strokes that the cache lacks
/// with the configured recognizer and exits.
/// A separate process keeps the MLX model's memory, about 7.8 GB in a measured run, out of the menu bar app,
/// and returns it when the run ends; a crash in a provider cannot stop the app.
/// Reads do not wait for it: `fetch_document` returns cached text and markers,
/// and the recognizer writes each page's result in its own short transaction.
/// `recognize.lock` keeps it from loading a model while `repossess` in another process recognizes.
public actor BackgroundRecognition {
    /// Why a run did not start.
    public enum Skip: Sendable, Equatable {
        case off
        /// The `client` provider needs an MCP client that samples; only `recognize_pages` can use it.
        case clientProvider
        case nothingWaits
        /// The pinned MLX model is not on the Mac; the owner starts its download in the settings.
        case modelMissing
        case alreadyRunning
        case helperMissing
    }

    /// What a run did.
    public struct Run: Sendable, Equatable {
        public var started: Date
        public var ended: Date
        public var exitStatus: Int32
        /// The last line that the command printed, such as "Recognized 3 pages in 12 s: …".
        public var lastLine: String
    }

    /// Runs the command and returns its exit status and its output.
    public typealias Launch = @Sendable () async throws -> (status: Int32, output: String)

    private let launch: Launch?
    private let clock: @Sendable () -> Date
    private var running = false
    public private(set) var lastRun: Run?

    /// - Parameter launch: Runs `repossess recognize`; `nil` when the helper is not beside the app.
    public init(launch: Launch?, clock: @escaping @Sendable () -> Date = Date.init) {
        self.launch = launch
        self.clock = clock
    }

    /// Whether a run is in progress.
    public var isRunning: Bool { running }

    /// Why a run would not start for a configuration, or `nil` when it would.
    public static func skipReason(
        configuration: RecognizerConfiguration?,
        waiting: Int,
        modelPresent: Bool
    ) -> Skip? {
        guard let configuration else { return .off }
        if configuration.provider == .client { return .clientProvider }
        if waiting <= 0 { return .nothingWaits }
        if configuration.provider == .mlx, configuration.modelPath == nil, !modelPresent { return .modelMissing }
        return nil
    }

    /// Starts a run unless one is running, and waits for it.
    /// - Returns: The run, or the reason that none started.
    public func run(
        configuration: RecognizerConfiguration?,
        waiting: Int,
        modelPresent: Bool
    ) async -> Result<Run, SkipError> {
        if let skip = Self.skipReason(configuration: configuration, waiting: waiting, modelPresent: modelPresent) {
            return .failure(SkipError(skip))
        }
        guard !running else { return .failure(SkipError(.alreadyRunning)) }
        guard let launch else { return .failure(SkipError(.helperMissing)) }
        running = true
        defer { running = false }
        let started = clock()
        let run: Run
        do {
            let (status, output) = try await launch()
            let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            run = Run(started: started, ended: clock(), exitStatus: status, lastLine: last)
        } catch {
            run = Run(started: started, ended: clock(), exitStatus: -1, lastLine: "\(error)")
        }
        lastRun = run
        if run.exitStatus == 0 {
            Log.recognition.notice("Recognition finished: \(run.lastLine)")
        } else {
            Log.recognition.error("Recognition exited with \(run.exitStatus): \(run.lastLine)")
        }
        return .success(run)
    }

    /// A reason as an error, so that it fits in a `Result`.
    public struct SkipError: Error, Equatable {
        public var skip: Skip
        public init(_ skip: Skip) { self.skip = skip }
    }
}

extension BackgroundRecognition {
    /// Runs `<helper> recognize --library <root>` at utility priority,
    /// and returns its exit status with its standard output and standard error.
    public static func processLaunch(helper: URL, libraryRoot: URL) -> Launch {
        {
            let process = Process()
            process.executableURL = helper
            process.arguments = ["recognize", "--library", libraryRoot.path]
            process.qualityOfService = .utility
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            // Read the pipe on its own thread, so that a long run cannot fill it and stall.
            let collected = OutputBuffer()
            let reading = DispatchGroup()
            reading.enter()
            DispatchQueue.global(qos: .utility).async {
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                reading.leave()
            }
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    try? pipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
            try? pipe.fileHandleForWriting.close()
            await withCheckedContinuation { continuation in
                reading.notify(queue: .global()) { continuation.resume() }
            }
            return (status, collected.text)
        }
    }
}

/// Collects a process's output from its pipe's handler.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
