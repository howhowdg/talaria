import Foundation
import HermesProtocol

/// Secret material for device-only Keychain storage, never preferences or diagnostics.
public struct GatewaySessionSnapshot: Codable, Sendable {
    struct Cookie: Codable, Sendable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let expires: Date?

        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain
            path = cookie.path; secure = cookie.isSecure; expires = cookie.expiresDate
        }
        var httpCookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if secure { properties[.secure] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)
        }
    }
    let connectionID: UUID
    let baseURL: URL
    let cookies: [Cookie]
    let expiresAt: Date?
}

/// All authenticated HTTP traffic shares this origin-bound cookie collection.
public actor GatewaySession: GatewayHTTPTransport {
    public nonisolated let endpoint: GatewayEndpoint
    private let credentialEndpoint: GatewayEndpoint
    private let http: any GatewayHTTPTransport
    private let token: String?
    private let onChange: (@Sendable (GatewaySessionSnapshot?) async -> Void)?
    private var cookies: [HTTPCookie] = []
    private var expiresAt: Date?
    private var verified = false
    private var invalidated = false
    private var generation = UUID()
    private var active: Task<GatewayHTTPResponse, Error>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var refresh: Task<Void, Error>?

    public init(endpoint: GatewayEndpoint, token: String) throws {
        try self.init(endpoint: endpoint, credentialEndpoint: endpoint, token: token, restored: nil, onChange: nil, http: URLSessionGatewayNetwork())
    }
    public init(endpoint: GatewayEndpoint, restored: GatewaySessionSnapshot? = nil,
                onChange: (@Sendable (GatewaySessionSnapshot?) async -> Void)? = nil) throws {
        try self.init(endpoint: endpoint, credentialEndpoint: endpoint, token: nil, restored: restored, onChange: onChange, http: URLSessionGatewayNetwork())
    }
    /// Only call after the SSH tunnel has been verified to reach this configured destination.
    public init(endpoint: GatewayEndpoint, credentialEndpoint: GatewayEndpoint, restored: GatewaySessionSnapshot? = nil,
                onChange: (@Sendable (GatewaySessionSnapshot?) async -> Void)? = nil) throws {
        try self.init(endpoint: endpoint, credentialEndpoint: credentialEndpoint, token: nil, restored: restored,
                      onChange: onChange, http: URLSessionGatewayNetwork())
    }
    init(endpoint: GatewayEndpoint, credentialEndpoint: GatewayEndpoint? = nil, token: String?, restored: GatewaySessionSnapshot? = nil,
         onChange: (@Sendable (GatewaySessionSnapshot?) async -> Void)? = nil, http: any GatewayHTTPTransport) throws {
        _ = try GatewayRoutes(endpoint: endpoint)
        let credentialEndpoint = credentialEndpoint ?? endpoint
        guard credentialEndpoint.id == endpoint.id, credentialEndpoint.profile == endpoint.profile,
              credentialEndpoint.authentication == endpoint.authentication else { throw GatewayTransportError.invalidEndpoint }
        if let token {
            guard !token.isEmpty else { throw GatewayTransportError.missingToken }
            guard !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
                throw GatewayTransportError.authenticationRejected
            }
        }
        self.endpoint = endpoint; self.credentialEndpoint = credentialEndpoint
        self.token = token; self.http = http; self.onChange = onChange
        if let restored {
            guard restored.connectionID == credentialEndpoint.id, restored.baseURL == credentialEndpoint.baseURL else { throw GatewayTransportError.invalidEndpoint }
            cookies = restored.cookies.compactMap(\.httpCookie).filter { Self.accepts($0, endpoint: endpoint) }
            expiresAt = restored.expiresAt
        }
    }

    public func snapshot() -> GatewaySessionSnapshot? {
        guard token == nil, !cookies.isEmpty else { return nil }
        return GatewaySessionSnapshot(connectionID: credentialEndpoint.id, baseURL: credentialEndpoint.baseURL,
                                      cookies: cookies.map(GatewaySessionSnapshot.Cookie.init), expiresAt: expiresAt)
    }

    public func login(username: String, password: String) async throws {
        guard token == nil else { throw GatewayTransportError.unsupportedAuthentication }
        await clear()
        invalidated = false
        let expected = generation
        let status = try await exchange(GatewayRoutes(endpoint: endpoint).statusRequest(token: nil), authenticated: false)
        let value = try json(status)
        let providers = value["auth_providers"]?.arrayValue ?? []
        guard providers.contains(where: { $0.stringValue == "basic" || $0["name"]?.stringValue == "basic" || $0["id"]?.stringValue == "basic" }) else {
            throw GatewayTransportError.unsupportedAuthentication
        }
        try check(expected)
        var request = try route("/auth/password-login", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["provider": "basic", "username": username, "password": password])
        let response = try await exchange(request, authenticated: false, login: true)
        guard try json(response)["ok"]?.boolValue == true else { throw GatewayTransportError.invalidResponse }
        try check(expected)
        try await validate()
    }

    public func validate() async throws {
        guard token == nil else { return }
        if let refresh { return try await refresh.value }
        let expected = generation
        let task = Task { try await self.probe(expected: expected) }
        refresh = task
        defer { if generation == expected { refresh = nil } }
        try await task.value
        try check(expected)
    }

    private func probe(expected: UUID) async throws {
        let response = try await exchange(route("/api/auth/me"), authenticated: true)
        try check(expected)
        let value = try json(response)
        guard value["provider"]?.stringValue == "basic", let expiry = value["expires_at"]?.intValue else {
            throw GatewayTransportError.invalidResponse
        }
        expiresAt = Date(timeIntervalSince1970: Double(expiry)); verified = true
        await onChange?(snapshot())
        try check(expected)
    }

    public func clear() async {
        invalidated = true
        generation = UUID(); active?.cancel(); refresh?.cancel(); refresh = nil
        cookies.removeAll(); expiresAt = nil; verified = false
    }

    /// Cancels work on a dead tunnel while retaining cookies for a verified reconnect.
    public func suspend() {
        invalidated = true
        generation = UUID(); active?.cancel(); refresh?.cancel(); refresh = nil
        verified = false
    }

    public func logout() async {
        var request = try? route("/auth/logout", method: "POST")
        if request != nil { request!.timeoutInterval = 10; attachCookies(to: &request!) }
        await clear()
        await onChange?(nil)
        if let request { _ = try? await http.data(for: request) }
    }

    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        let expected = generation
        if token == nil, !verified || (expiresAt.map { $0 <= Date() } ?? false) { try await validate() }
        try check(expected)
        return try await exchange(request, authenticated: true)
    }

    func socketRequest() async throws -> URLRequest {
        let expected = generation
        if let token {
            let response = try await exchange(GatewayRoutes(endpoint: endpoint).statusRequest(token: token), authenticated: true)
            let status = try json(response)
            if status["auth_required"]?.boolValue == true { throw GatewayTransportError.interactiveAuthenticationRequired }
            return try GatewayRoutes(endpoint: endpoint).socketRequest(token: token)
        }
        try await validate()
        let response = try await data(for: route("/api/auth/ws-ticket", method: "POST"))
        try check(expected)
        guard let ticket = try json(response)["ticket"]?.stringValue, !ticket.isEmpty else { throw GatewayTransportError.invalidResponse }
        var request = try GatewayRoutes(endpoint: endpoint).socketRequest(token: ticket)
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = url.queryItems?.map { $0.name == "token" ? URLQueryItem(name: "ticket", value: ticket) : $0 }
        request.url = url.url
        return request
    }

    private func route(_ path: String, method: String = "GET") throws -> URLRequest {
        var request = try GatewayRoutes(endpoint: endpoint).statusRequest(token: nil)
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.path = String(url.path.dropLast("/api/status".count)) + path
        request.url = url.url; request.httpMethod = method
        return request
    }

    private func exchange(_ original: URLRequest, authenticated: Bool, login: Bool = false) async throws -> GatewayHTTPResponse {
        let expected = generation
        // ponytail: serialize HTTP, including uploads; split only if measured contention warrants it.
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer {
            active = nil
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        try check(expected)
        guard !invalidated else { throw GatewayTransportError.notConnected }
        guard let url = original.url, Self.contains(url, endpoint: endpoint) else { throw GatewayTransportError.invalidEndpoint }
        var request = original
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "X-Hermes-Session-Token")
        if authenticated {
            if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }
            else { attachCookies(to: &request) }
        }
        let transport = http
        let task = Task { try await transport.data(for: request) }
        active = task
        let response: GatewayHTTPResponse
        do { response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { try check(expected); throw GatewayTransportError.connectionFailed }
        try check(expected)
        if token == nil, authenticated || login {
            var changed = false
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: response.headers, for: url) where Self.accepts(cookie, endpoint: endpoint) {
                changed = true
                cookies.removeAll { $0.name == cookie.name && $0.path == cookie.path }
                if !cookie.value.isEmpty, cookie.expiresDate.map({ $0 > Date() }) ?? true { cookies.append(cookie) }
            }
            if changed, verified { await onChange?(snapshot()); try check(expected) }
        }
        switch response.status {
        case 200..<300: return response
        case 401:
            if login { throw GatewayTransportError.invalidCredentials }
            if token == nil {
                cookies.removeAll(); verified = false; expiresAt = nil
                await onChange?(nil)
                throw GatewayTransportError.sessionExpired
            }
            throw GatewayTransportError.authenticationRejected
        case 400 where GatewayClient.isKnownHostRejection(response.data): throw GatewayTransportError.hostRejected
        case 403: throw GatewayTransportError.authenticationRejected
        case 404 where login: throw GatewayTransportError.unsupportedAuthentication
        case 429: throw GatewayTransportError.rateLimited
        case 503: throw GatewayTransportError.authenticationUnavailable
        default: throw GatewayTransportError.httpStatus(response.status)
        }
    }

    private func attachCookies(to request: inout URLRequest) {
        guard let url = request.url else { return }
        let selected = cookies.filter { cookie in
            (cookie.expiresDate.map { $0 > Date() } ?? true) && (!cookie.isSecure || url.scheme == "https") && Self.path(url.path, liesUnder: cookie.path)
        }
        for (key, value) in HTTPCookie.requestHeaderFields(with: selected) { request.setValue(value, forHTTPHeaderField: key) }
    }
    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw GatewayTransportError.connectionChanged }
    }
    private func json(_ response: GatewayHTTPResponse) throws -> JSONValue {
        guard response.data.count <= 1_048_576, let value = try? JSONDecoder().decode(JSONValue.self, from: response.data), value.objectValue != nil else { throw GatewayTransportError.invalidResponse }
        return value
    }
    private static func path(_ path: String, liesUnder prefix: String) -> Bool {
        let prefix = prefix == "/" ? "" : prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty || path == "/" + prefix || path.hasPrefix("/" + prefix + "/")
    }
    private static func contains(_ url: URL, endpoint: GatewayEndpoint) -> Bool {
        url.scheme?.lowercased() == endpoint.baseURL.scheme?.lowercased() &&
        url.host?.lowercased() == endpoint.baseURL.host?.lowercased() &&
        (url.port ?? (url.scheme == "https" ? 443 : 80)) == (endpoint.baseURL.port ?? (endpoint.baseURL.scheme == "https" ? 443 : 80)) &&
        path(url.path, liesUnder: endpoint.baseURL.path)
    }
    private static func accepts(_ cookie: HTTPCookie, endpoint: GatewayEndpoint) -> Bool {
        let names = ["hermes_session_at", "hermes_session_rt", "hermes_session_provider"]
        let allowed = ["", "__Host-", "__Secure-"].flatMap { prefix in names.map { prefix + $0 } }
        guard allowed.contains(cookie.name),
              cookie.domain.lowercased() == endpoint.baseURL.host?.lowercased(),
              path(endpoint.baseURL.path.isEmpty ? "/" : endpoint.baseURL.path, liesUnder: cookie.path) else { return false }
        if cookie.name.hasPrefix("__Host-") && (!cookie.isSecure || cookie.path != "/") { return false }
        if cookie.name.hasPrefix("__Secure-") && !cookie.isSecure { return false }
        return !cookie.isSecure || endpoint.baseURL.scheme == "https"
    }
}
