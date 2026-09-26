import Foundation

public enum GatewayAuthentication: String, Codable, Sendable {
    case sessionToken, basic
}

public struct GatewaySSHDestination: Codable, Sendable, Equatable {
    public var host: String
    public var user: String?
    public var sshPort: Int
    public var identityFile: String?
    public var gatewayPort: Int
    public var gatewayPath: String
    public var useExistingGateway: Bool?
    public var attachesExistingGateway: Bool {
        useExistingGateway ?? (gatewayPort != 9119 || !gatewayPath.isEmpty && gatewayPath != "/")
    }

    public init(host: String, user: String? = nil, sshPort: Int = 22, identityFile: String? = nil,
                gatewayPort: Int = 9119, gatewayPath: String = "", useExistingGateway: Bool? = nil) {
        self.host = host; self.user = user; self.sshPort = sshPort
        self.identityFile = identityFile; self.gatewayPort = gatewayPort; self.gatewayPath = gatewayPath
        self.useExistingGateway = useExistingGateway
    }

    public static func parse(_ input: String) -> Self? {
        let value = input.trimmingCharacters(in: .whitespaces)
        let target = value.hasPrefix("ssh ") ? String(value.dropFirst(4)).trimmingCharacters(in: .whitespaces) : value
        let userAndHost = target.split(separator: "@", omittingEmptySubsequences: false)
        guard userAndHost.count <= 2 else { return nil }
        let hostAndPort = userAndHost.last!.split(separator: ":", omittingEmptySubsequences: false)
        guard hostAndPort.count <= 2 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let host = String(hostAndPort[0])
        let user = userAndHost.count == 2 ? String(userAndHost[0]) : nil
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
              user == nil || (!user!.isEmpty && !user!.hasPrefix("-") && user!.unicodeScalars.allSatisfy(allowed.contains)) else { return nil }
        let port: Int
        if hostAndPort.count == 2 {
            guard let parsed = Int(hostAndPort[1]), (1...65_535).contains(parsed),
                  hostAndPort[1].allSatisfy(\.isNumber) else { return nil }
            port = parsed
        } else { port = 22 }
        return Self(host: host, user: user, sshPort: port)
    }
}

/// Persistable routing information. Credentials are deliberately supplied separately.
public struct GatewayEndpoint: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var baseURL: URL
    public var authentication: GatewayAuthentication
    public var profile: String
    public var ssh: GatewaySSHDestination?

    public init(id: UUID = UUID(), name: String, baseURL: URL, profile: String = "default", authentication: GatewayAuthentication = .sessionToken,
                ssh: GatewaySSHDestination? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.profile = profile
        self.authentication = authentication
        self.ssh = ssh
    }
    private enum CodingKeys: String, CodingKey { case id, name, baseURL, profile, authentication, ssh }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        profile = try values.decode(String.self, forKey: .profile)
        authentication = try values.decodeIfPresent(GatewayAuthentication.self, forKey: .authentication) ?? .sessionToken
        ssh = try values.decodeIfPresent(GatewaySSHDestination.self, forKey: .ssh)
    }

}

public enum GatewayTransportError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case missingToken
    case interactiveAuthenticationRequired
    case unsupportedAuthentication
    case invalidCredentials
    case sessionExpired
    case rateLimited
    case authenticationUnavailable
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
            "Use HTTPS, or HTTP on localhost or a Tailscale 100.x address. Remove credentials, query parameters and fragments from the URL."
        case .missingToken:
            "Enter this Hermes serve instance's session token. Token-mode WebSocket connections require a token, including on localhost."
        case .interactiveAuthenticationRequired:
            "This gateway uses gated authentication and one-use WebSocket tickets. Choose username and password authentication for this gateway."
        case .unsupportedAuthentication: "This gateway does not offer username and password sign-in."
        case .invalidCredentials: "The username or password was not accepted."
        case .sessionExpired: "Your sign-in expired. Sign in again."
        case .rateLimited: "Too many sign-in attempts. Try again shortly."
        case .authenticationUnavailable: "The sign-in provider is temporarily unavailable. Try again later."
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
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        let tailscale = parts.count == 4 && octets.count == 4 &&
            zip(parts, octets).allSatisfy { $0 == String($1) } &&
            octets[0] == 100 && (64...127).contains(octets[1])
        guard scheme == "https" || (scheme == "http" && (loopback || tailscale)) else {
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
