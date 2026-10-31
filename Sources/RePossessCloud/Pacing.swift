import Foundation

/// How ``PacedTransport`` paces requests.
public struct Pacing: Sendable {
    /// The most requests in flight at once.
    public var maxConcurrent: Int
    /// How many times a read is sent again after HTTP 429 or a 5xx status.
    public var maxRetries: Int
    /// The longest single wait, whatever the server asks for.
    public var maxWait: Duration
    /// Waits; tests replace it to record waits without sleeping.
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        maxConcurrent: Int = 4,
        maxRetries: Int = 3,
        maxWait: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maxConcurrent = max(maxConcurrent, 1)
        self.maxRetries = max(maxRetries, 0)
        self.maxWait = maxWait
        self.sleep = sleep
    }
}

/// What a transport sent and received.
public struct TransportUsage: Sendable, Equatable {
    /// Requests sent, including retries.
    public var requests = 0
    /// Bytes in response bodies.
    public var bytes = 0
    /// Requests sent again after HTTP 429 or a 5xx status.
    public var retries = 0
    /// Pauses for a rate limit.
    public var waits = 0

    public init() {}

    /// The usage between two readings.
    public static func - (later: TransportUsage, earlier: TransportUsage) -> TransportUsage {
        var result = TransportUsage()
        result.requests = later.requests - earlier.requests
        result.bytes = later.bytes - earlier.bytes
        result.retries = later.retries - earlier.retries
        result.waits = later.waits - earlier.waits
        return result
    }
}

/// The rate-limit headers of a response.
///
/// On 2026-10-25 the cloud service sent `x-ratelimit-limit`, `x-ratelimit-remaining`,
/// and `x-ratelimit-reset` on every response: for file reads 48000, 95998, and 1;
/// for the root 30, 29, and 2; and for user tokens 5, 2 to 4, and 12 to 26.
/// That the reset is in seconds is an inference from those values.
struct RateLimit: Equatable {
    var limit: Int?
    var remaining: Int?
    var reset: Duration?
    var retryAfter: Duration?

    init(headers: [String: String]) {
        func number(_ name: String) -> Double? {
            headers[name].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
        }
        limit = number("x-ratelimit-limit").map { Int($0) }
        remaining = number("x-ratelimit-remaining").map { Int($0) }
        reset = number("x-ratelimit-reset").map { .milliseconds(Int64($0 * 1000)) }
        retryAfter = number("retry-after").map { .milliseconds(Int64($0 * 1000)) }
    }
}

/// Sends requests to reMarkable's cloud with bounded concurrency, and honors its rate limits.
///
/// - At most ``Pacing/maxConcurrent`` requests are in flight at once.
/// - Requests share a limit when they have the same host and path, apart from a blob's hash.
///   When a response leaves fewer requests than ``Pacing/maxConcurrent`` in the window,
///   the next request with that limit waits for `x-ratelimit-reset` seconds.
/// - A `GET` that gets HTTP 429 or a 5xx status is sent again, up to ``Pacing/maxRetries`` times,
///   after `retry-after`, `x-ratelimit-reset`, or 1, 2, then 4 seconds.
///   Other methods are never sent again, because a lost response may hide a write that succeeded.
public actor PacedTransport: HTTPTransport {
    let base: any HTTPTransport
    let pacing: Pacing
    private var inFlight = 0
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var pauses: [String: Task<Void, Never>] = [:]
    /// What this transport has sent and received.
    public private(set) var usage = TransportUsage()

    public init(base: any HTTPTransport, pacing: Pacing = Pacing()) {
        self.base = base
        self.pacing = pacing
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let key = Self.limitKey(for: request.url)
        var attempt = 0
        while true {
            if let pause = pauses[key] { await pause.value }
            await acquire()
            let response: HTTPResponse
            do {
                response = try await base.send(request)
            } catch {
                release()
                throw error
            }
            release()
            usage.requests += 1
            usage.bytes += response.body.count
            let limit = RateLimit(headers: response.headers)
            let retryable = response.status == 429 || (500 ..< 600).contains(response.status)
            if retryable, request.method == "GET", attempt < pacing.maxRetries {
                attempt += 1
                usage.retries += 1
                pause(key, for: limit.retryAfter ?? limit.reset ?? .seconds(1 << (attempt - 1)))
                continue
            }
            if let remaining = limit.remaining, remaining < pacing.maxConcurrent, let reset = limit.reset {
                pause(key, for: reset)
            }
            return response
        }
    }

    /// The key of the limit that a request counts against: its host and path,
    /// without a blob's hash, so that every file read shares one limit.
    static func limitKey(for url: URL) -> String {
        var parts = url.path().split(separator: "/")
        if let last = parts.last, ContentHash.isValid(String(last)) { parts.removeLast() }
        return (url.host() ?? "") + "/" + parts.joined(separator: "/")
    }

    private func pause(_ key: String, for duration: Duration) {
        let wait = min(duration, pacing.maxWait)
        guard wait > .zero else { return }
        usage.waits += 1
        let sleep = pacing.sleep
        pauses[key] = Task { try? await sleep(wait) }
    }

    private func acquire() async {
        if inFlight < pacing.maxConcurrent {
            inFlight += 1
            return
        }
        // The slot passes directly from the releasing request.
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty {
            inFlight -= 1
        } else {
            queue.removeFirst().resume()
        }
    }
}
