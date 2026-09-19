import Foundation

/// Persistable routing information. Credentials are deliberately supplied separately.
public struct GatewayEndpoint: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var baseURL: URL
    public var profile: String

    public init(id: UUID = UUID(), name: String, baseURL: URL, profile: String = "default") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.profile = profile
    }
}

public enum GatewayTransportError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case missingToken
    case interactiveAuthenticationRequired
    case authenticationRejected
    case hostRejected
    case httpStatus(Int)
    case invalidResponse
    case notConnected
    case connectionChanged
    case connectionFailed
    case consumerTooSlow
    case readyTimedOut
    case requestTimedOut
    case unknownServerRequest

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Use an HTTPS gateway URL, or HTTP on localhost/127.0.0.1/::1. Remove credentials, query parameters and fragments from the URL."
        case .missingToken:
            "Enter this Hermes serve instance's session token. Token-mode WebSocket connections require a token, including on localhost."
        case .interactiveAuthenticationRequired:
            "This gateway uses gated authentication and one-use WebSocket tickets. This native preview supports session-token gateways; use a token-mode Hermes serve endpoint. Gated sign-in is not implemented yet."
        case .authenticationRejected:
            "The gateway rejected authentication. Check the session token and gateway configuration."
        case .hostRejected:
            "Hermes rejected the gateway hostname. Use the hostname the server was bound to. For an SSH tunnel to Hermes bound to 127.0.0.1, forward to 127.0.0.1 and its listening port on the remote host."
        case .httpStatus(let status):
            "The gateway status request failed (HTTP \(status))."
        case .invalidResponse:
            "The gateway returned an invalid protocol response. Verify that this URL points to Hermes serve."
        case .notConnected:
            "Connect to a Hermes gateway before sending a request."
        case .connectionChanged:
            "The gateway connection changed before this operation completed."
        case .connectionFailed:
            "The gateway connection failed. Check the host, network and token, then reconnect. An interrupted send may already have reached the host."
        case .consumerTooSlow:
            "The client could not keep up with live updates. Reconnect to restore the session from the host before sending more work."
        case .readyTimedOut:
            "The gateway did not finish its ready handshake. Check the host and reconnect."
        case .requestTimedOut:
            "The gateway did not acknowledge the request before its deadline. It may still be running; reconcile the session before retrying."
        case .unknownServerRequest:
            "This request is no longer pending on this connection. Refresh the session before answering."
        }
    }
}

/// Builds routes without allowing device secrets in the persistable base URL.
struct GatewayRoutes {
    let endpoint: GatewayEndpoint
    private let components: URLComponents

    init(endpoint: GatewayEndpoint) throws {
        guard let components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !endpoint.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayTransportError.invalidEndpoint
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw GatewayTransportError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.components = components
    }

    func statusRequest(token: String?) throws -> URLRequest {
        var route = components
        route.path = route.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).reduce("") { $0 + "/" + $1 } + "/api/status"
        route.queryItems = [URLQueryItem(name: "profile", value: endpoint.profile)]
        guard let url = route.url else { throw GatewayTransportError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        return request
    }

    func socketRequest(token: String) throws -> URLRequest {
        var route = components
        route.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        route.path = route.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).reduce("") { $0 + "/" + $1 } + "/api/ws"
        route.queryItems = [URLQueryItem(name: "profile", value: endpoint.profile), URLQueryItem(name: "token", value: token)]
        guard let url = route.url else { throw GatewayTransportError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        return request
    }
}
