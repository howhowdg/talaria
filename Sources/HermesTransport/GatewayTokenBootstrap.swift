import Foundation
import HermesProtocol

/// Reads the headless dashboard token only through an already verified SSH tunnel.
public enum GatewayTokenBootstrap {
    public static func token(through endpoint: GatewayEndpoint) async throws -> String {
        try await token(through: endpoint, http: URLSessionGatewayNetwork())
    }

    static func token(through endpoint: GatewayEndpoint, http: any GatewayHTTPTransport) async throws -> String {
        let routes = try GatewayRoutes(endpoint: endpoint)
        let status = try await http.data(for: routes.statusRequest(token: nil))
        guard status.status == 200, status.data.count <= 65_536,
              let value = try? JSONDecoder().decode([String: JSONValue].self, from: status.data),
              let gated = value["auth_required"]?.boolValue else { throw GatewayTransportError.invalidResponse }
        guard !gated else { throw GatewayTransportError.interactiveAuthenticationRequired }

        var root = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        root.path = root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).reduce("") { $0 + "/" + $1 } + "/"
        guard let url = root.url else { throw GatewayTransportError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let response = try await http.data(for: request)
        guard response.status == 200, response.data.count <= 65_536,
              let body = String(data: response.data, encoding: .utf8) else { throw GatewayTransportError.invalidResponse }
        let pattern = #"window\.__HERMES_SESSION_TOKEN__\s*=\s*("(?:\\.|[^"\\])*")\s*;?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              let capture = Range(match.range(at: 1), in: body),
              let token = try? JSONDecoder().decode(String.self, from: Data(body[capture].utf8)),
              !token.isEmpty,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw GatewayTransportError.missingToken
        }
        return token
    }
}
