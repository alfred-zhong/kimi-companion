import Foundation

public protocol HTTPClient: Sendable {
    /// GET；非 2xx 由实现转成 `HTTPError` 抛出。
    func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPError: Error, Equatable, Sendable {
    case timeout
    case unauthorized(status: Int)
    case rateLimited
    case server(status: Int)
    case invalidResponse
    case missingCredential
}

/// 只走 HTTPS 的 `URLSession.shared` 实现。未配 `NSAppTransportSecurity` 例外。
public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpMethod = "GET"
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else { throw HTTPError.invalidResponse }
            switch http.statusCode {
            case 200..<300: return (data, http)
            case 401, 403: throw HTTPError.unauthorized(status: http.statusCode)
            case 429: throw HTTPError.rateLimited
            default: throw HTTPError.server(status: http.statusCode)
            }
        } catch let e as URLError where e.code == .timedOut {
            throw HTTPError.timeout
        }
    }
}
