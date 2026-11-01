import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var data: Data
    public var finalURL: URL?

    public init(status: Int, data: Data, finalURL: URL? = nil) {
        self.status = status
        self.data = data
        self.finalURL = finalURL
    }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    /// Retries on 429/503, waiting `Retry-After` seconds (capped) or 2, 4, 8 s.
    public var maxRetries: Int

    public init(maxRetries: Int = 3) {
        self.maxRetries = maxRetries
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if [429, 503].contains(status), attempt < maxRetries {
                let advised = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                try await Task.sleep(for: .seconds(min(advised ?? pow(2, Double(attempt + 1)), 30)))
                attempt += 1
                continue
            }
            return HTTPResponse(status: status, data: data, finalURL: http?.url)
        }
    }
}

public enum SearchError: Error, CustomStringConvertible {
    case http(status: Int, url: URL)
    case decoding(String)

    public var description: String {
        switch self {
        case .http(let status, let url): "HTTP \(status) from \(url.absoluteString)"
        case .decoding(let message): "could not decode response: \(message)"
        }
    }
}
