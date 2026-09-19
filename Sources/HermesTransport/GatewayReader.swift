import Foundation
import HermesProtocol

/// The read-only dashboard endpoints used by the native activity feed. Callers
/// cannot supply an arbitrary URL or change the credential's origin.
public enum GatewayReadEndpoint: Sendable, Equatable {
    case schedules
    /// Optional Talaria host extension. A 404 means topic discovery is unavailable.
    case telegramTopics
    case scheduleRuns(id: String, limit: Int)
    case sessionMessages(id: String, limit: Int)
}

public struct GatewayReader: Sendable {
    private let endpoint: GatewayEndpoint
    private let token: String
    private let http: any GatewayHTTPTransport

    public init(endpoint: GatewayEndpoint, token: String) {
        self.init(endpoint: endpoint, token: token, http: URLSessionGatewayNetwork())
    }

    init(endpoint: GatewayEndpoint, token: String, http: any GatewayHTTPTransport) {
        self.endpoint = endpoint; self.token = token; self.http = http
    }

    public func setAutomationEnabled(id: String, enabled: Bool) async throws -> JSONValue {
        try await perform(GatewayRoutes(endpoint: endpoint).automationRequest(id: id, action: enabled ? "resume" : "pause", token: token))
    }

    public func triggerAutomation(id: String) async throws -> JSONValue {
        try await perform(GatewayRoutes(endpoint: endpoint).automationRequest(id: id, action: "trigger", token: token))
    }

    public func read(_ resource: GatewayReadEndpoint) async throws -> JSONValue {
        try Task.checkCancellation()
        let request = try GatewayRoutes(endpoint: endpoint).readRequest(resource, token: token)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> JSONValue {
        try Task.checkCancellation()
        let response = try await http.data(for: request)
        try Task.checkCancellation()
        guard response.status != 401 && response.status != 403 else {
            throw GatewayTransportError.authenticationRejected
        }
        guard (200..<300).contains(response.status) else { throw GatewayTransportError.httpStatus(response.status) }
        // Dashboard payloads include host metadata. Keep retention bounded even
        // if an older host ignores the requested page size.
        guard response.data.count <= 8 * 1_024 * 1_024 else { throw GatewayTransportError.invalidResponse }
        do { return try JSONDecoder().decode(JSONValue.self, from: response.data) }
        catch { throw GatewayTransportError.invalidResponse }
    }
}

extension GatewayRoutes {
    func readRequest(_ resource: GatewayReadEndpoint, token: String) throws -> URLRequest {
        guard !token.isEmpty else { throw GatewayTransportError.missingToken }
        var request = try statusRequest(token: token)
        guard let url = request.url, var route = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GatewayTransportError.invalidEndpoint
        }
        let suffix: String
        var query = [URLQueryItem(name: "profile", value: endpoint.profile)]
        switch resource {
        case .schedules: suffix = "/cron/jobs"
        case .telegramTopics: suffix = "/talaria/telegram/topics"
        case .scheduleRuns(let id, let limit):
            suffix = "/cron/jobs/\(try encodedSegment(id))/runs"
            query.append(URLQueryItem(name: "limit", value: String(max(1, min(limit, 20)))))
        case .sessionMessages(let id, let limit):
            suffix = "/sessions/\(try encodedSegment(id))/messages"
            query += [URLQueryItem(name: "limit", value: String(max(1, min(limit, 40)))),
                      URLQueryItem(name: "order", value: "latest"),
                      URLQueryItem(name: "include_compacted", value: "true")]
        }
        // statusRequest preserves an optional reverse-proxy path prefix.
        route.percentEncodedPath = String(route.percentEncodedPath.dropLast("/status".count)) + suffix
        route.queryItems = query
        guard let resolved = route.url else { throw GatewayTransportError.invalidEndpoint }
        request.url = resolved; request.httpMethod = "GET"; request.timeoutInterval = 30
        return request
    }

    func automationRequest(id: String, action: String, token: String) throws -> URLRequest {
        guard ["resume", "pause", "trigger"].contains(action) else { throw GatewayTransportError.invalidResponse }
        var request = try readRequest(.scheduleRuns(id: id, limit: 1), token: token)
        guard let url = request.url, var route = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GatewayTransportError.invalidEndpoint
        }
        route.percentEncodedPath = String(route.percentEncodedPath.dropLast("runs".count)) + action
        route.queryItems = [URLQueryItem(name: "profile", value: endpoint.profile)]
        request.url = route.url; request.httpMethod = "POST"; request.timeoutInterval = 60
        return request
    }

    private func encodedSegment(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let encoded = value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else {
            throw GatewayTransportError.invalidResponse
        }
        return encoded
    }
}
