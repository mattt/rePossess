import Foundation

/// An HTTP request as a plain value, so that tests can inspect it without a network.
public struct HTTPRequest: Sendable, Equatable {
    /// The HTTP method, such as `GET` or `PUT`.
    public var method: String
    /// The absolute URL of the request.
    public var url: URL
    /// The header fields, with names in lowercase.
    public var headers: [String: String]
    /// The body, if the request has one.
    public var body: Data?

    /// Creates a request.
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    /// A one-line description with the bearer token removed.
    public var redactedDescription: String {
        let names = headers.keys.sorted().map { name -> String in
            name == "authorization" ? "authorization: Bearer <redacted>" : "\(name): \(headers[name]!)"
        }
        return "\(method) \(url.absoluteString) [\(names.joined(separator: "; "))] body=\(body?.count ?? 0) bytes"
    }
}

/// An HTTP response as a plain value.
public struct HTTPResponse: Sendable, Equatable {
    /// The status code.
    public var status: Int
    /// The header fields, with names in lowercase.
    public var headers: [String: String]
    /// The body.
    public var body: Data

    /// Creates a response.
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    /// The body decoded as UTF-8, or an empty string.
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// Sends HTTP requests.
///
/// The live client uses ``URLSessionTransport``;
/// tests inject a fake that never touches the network.
public protocol HTTPTransport: Sendable {
    /// Sends a request and returns the response, whatever its status.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// A transport that sends requests with `URLSession`,
/// and only to reMarkable's hosts.
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    /// Creates a transport with an ephemeral session, which keeps no cookies or cache on disk.
    ///
    /// A request fails after `timeout` seconds without data, and after `resourceTimeout` in all.
    public init(timeout: TimeInterval = 30, resourceTimeout: TimeInterval = 300) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = resourceTimeout
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard CloudHosts.isAllowed(request.url) else {
            throw CloudError.hostNotAllowed(request.url.host() ?? request.url.absoluteString)
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        // Authorization is a reserved header in Foundation's documentation,
        // but URLSession sent it unchanged in spike 6's live run (2026-10-25).
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.notHTTP
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
