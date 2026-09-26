import Foundation

struct GatewayHTTPResponse: Sendable {
    let data: Data
    let status: Int
    var headers: [String: String] = [:]
}

protocol GatewayHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse
}

protocol GatewaySocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close() async
}

typealias GatewaySocketFactory = @Sendable (URLRequest) -> any GatewaySocket

/// Redirects are denied so a status response cannot redirect a session token to another origin.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class URLSessionGatewayNetwork: GatewayHTTPTransport, @unchecked Sendable {
    private let httpSession: URLSession
    private let socketSession: URLSession

    init() {
        let statusConfiguration = Self.configuration()
        statusConfiguration.timeoutIntervalForResource = 90
        httpSession = URLSession(configuration: statusConfiguration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        // A long-lived socket must not inherit the finite status-download deadline.
        // The client bounds readiness and checks the host's heartbeat separately.
        socketSession = URLSession(configuration: Self.configuration(), delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        return configuration
    }

    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        let (data, response) = try await httpSession.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GatewayTransportError.invalidResponse }
        return GatewayHTTPResponse(data: data, status: response.statusCode,
                                   headers: response.allHeaderFields.reduce(into: [:]) { fields, entry in
                                       fields[String(describing: entry.key)] = String(describing: entry.value)
                                   })
    }

    func socket(for request: URLRequest) -> any GatewaySocket {
        let task = socketSession.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1_024 * 1_024
        task.resume()
        return URLSessionGatewaySocket(task: task)
    }
}

private final class URLSessionGatewaySocket: GatewaySocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else { throw GatewayTransportError.invalidResponse }
            return text
        @unknown default: throw GatewayTransportError.invalidResponse
        }
    }

    func close() async { task.cancel(with: .goingAway, reason: nil) }
}
