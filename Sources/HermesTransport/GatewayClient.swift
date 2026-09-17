import Foundation
import HermesProtocol

public enum GatewayUpdate: Sendable {
    case connected
    case disconnected(String?)
    case event(GatewayEvent)
    case snapshot(method: String, result: JSONValue)
    case request(GatewayServerRequest)
}

struct GatewayTiming: Sendable {
    var readyTimeout: TimeInterval = 15
    var heartbeatInterval: TimeInterval = 20
    var heartbeatTimeout: TimeInterval = 10
}

/// One endpoint and socket generation. Reconnection and authoritative session hydration
/// are explicit caller decisions; this actor never retries a submitted mutation.
public actor GatewayClient {
    private struct OutboundFrame: Encodable, Sendable {
        var jsonrpc = "2.0"
        let id: RPCID
        var method: String?
        var params: JSONValue?
        var result: JSONValue?
        var error: JSONValue?
    }

    private struct FrameIdentity: Decodable {
        let id: RPCID?
    }

    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timer: Task<Void, Never>
    }

    private let http: any GatewayHTTPTransport
    private let makeSocket: GatewaySocketFactory
    private let timing: GatewayTiming
    private var socket: (any GatewaySocket)?
    private var generation = UUID()
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var readyTimer: Task<Void, Never>?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var sawReady = false
    private var isConnected = false
    private var heartbeatSupported = false
    private var pending: [RPCID: Pending] = [:]
    private var serverRequests: Set<RPCID> = []
    private var subscribers: [UUID: AsyncStream<GatewayUpdate>.Continuation] = [:]

    public init() {
        let network = URLSessionGatewayNetwork()
        http = network
        makeSocket = { network.socket(for: $0) }
        timing = GatewayTiming()
    }

    init(http: any GatewayHTTPTransport, socketFactory: @escaping GatewaySocketFactory, timing: GatewayTiming = GatewayTiming()) {
        self.http = http
        makeSocket = socketFactory
        self.timing = timing
    }

    public func updates() -> AsyncStream<GatewayUpdate> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2_048)) { continuation in
            subscribers[id] = continuation
            if isConnected { continuation.yield(.connected) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    public func connect(to endpoint: GatewayEndpoint, token: String?) async throws {
        // Validation happens before replacing a usable connection.
        let routes = try GatewayRoutes(endpoint: endpoint)
        let oldSocket = socket
        let hadConnection = isConnected || sawReady || receiver != nil
        let connectionGeneration = UUID()
        generation = connectionGeneration
        socket = nil
        clearConnection(error: GatewayTransportError.connectionChanged)
        if hadConnection { publish(.disconnected(nil)) }
        do {
            await oldSocket?.close()
            try checkGeneration(connectionGeneration)
            try Task.checkCancellation()
            let response = try await http.data(for: routes.statusRequest(token: token))
            try checkGeneration(connectionGeneration)
            guard response.status != 401 && response.status != 403 else {
                throw GatewayTransportError.authenticationRejected
            }
            guard (200..<300).contains(response.status) else { throw GatewayTransportError.httpStatus(response.status) }
            let status = try JSONDecoder().decode(JSONValue.self, from: response.data)
            guard status.objectValue != nil else { throw GatewayTransportError.invalidResponse }
            if status["auth_required"]?.boolValue == true {
                throw GatewayTransportError.interactiveAuthenticationRequired
            }
            guard let token, !token.isEmpty else { throw GatewayTransportError.missingToken }
            try Task.checkCancellation()
            let newSocket = makeSocket(try routes.socketRequest(token: token))
            socket = newSocket
            receiver = Task { [weak self] in
                await self?.receiveFrames(from: newSocket, generation: connectionGeneration)
            }
            try await waitUntilReady(generation: connectionGeneration)
            try checkGeneration(connectionGeneration)
            _ = try await request("client.capabilities", params: .object(["server_requests": .bool(true)]), timeout: 10)
            try checkGeneration(connectionGeneration)
            try Task.checkCancellation()
            isConnected = true
            publish(.connected)
            if heartbeatSupported { startHeartbeat(generation: connectionGeneration) }
        } catch {
            let safeError: Error
            if error is CancellationError { safeError = CancellationError() }
            else if let transportError = error as? GatewayTransportError { safeError = transportError }
            else if let rpcError = error as? JSONRPCError { safeError = rpcError }
            else { safeError = GatewayTransportError.connectionFailed }
            await failConnection(generation: connectionGeneration, error: safeError)
            throw safeError
        }
    }

    public func disconnect() async {
        let oldSocket = socket
        generation = UUID()
        socket = nil
        let hadConnection = isConnected || sawReady || receiver != nil
        clearConnection(error: GatewayTransportError.notConnected)
        if hadConnection { publish(.disconnected(nil)) }
        await oldSocket?.close()
    }

    /// Cancelling this local wait does not interrupt a host-side turn. Use session.interrupt
    /// for that explicit operation. A timed out or cancelled send is never automatically replayed.
    public func request(_ method: String, params: JSONValue = .object([:]), timeout: TimeInterval = 30) async throws -> JSONValue {
        guard socket != nil, sawReady else { throw GatewayTransportError.notConnected }
        try Task.checkCancellation()
        let id = RPCID.string("native-\(UUID().uuidString)")
        let connectionGeneration = generation
        let frame = OutboundFrame(id: id, method: method, params: params)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = Task { [weak self] in
                    do { try await Self.sleep(timeout) } catch { return }
                    await self?.finishPending(id, generation: connectionGeneration, result: .failure(GatewayTransportError.requestTimedOut))
                }
                pending[id] = Pending(method: method, continuation: continuation, timer: timer)
                Task { [weak self] in
                    await self?.sendRequest(frame, id: id, generation: connectionGeneration)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.finishPending(id, generation: connectionGeneration, result: .failure(CancellationError()))
            }
        }
    }

    public func respond(to id: RPCID, result: JSONValue) async throws {
        try await answer(id, member: "result", value: result)
    }

    public func reject(_ id: RPCID, code: Int, message: String) async throws {
        try await answer(id, member: "error", value: .object(["code": .number(Double(code)), "message": .string(message)]))
    }

    private func answer(_ id: RPCID, member: String, value: JSONValue) async throws {
        guard let socket, sawReady else { throw GatewayTransportError.notConnected }
        guard serverRequests.remove(id) != nil else { throw GatewayTransportError.unknownServerRequest }
        let connectionGeneration = generation
        do {
            var frame = OutboundFrame(id: id)
            if member == "result" { frame.result = value } else { frame.error = value }
            try await socket.send(try encoded(frame))
            try checkGeneration(connectionGeneration)
        } catch {
            await failConnection(generation: connectionGeneration, error: GatewayTransportError.connectionFailed)
            throw GatewayTransportError.connectionFailed
        }
    }

    private func waitUntilReady(generation expected: UUID) async throws {
        if sawReady { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                readyWaiter = continuation
                readyTimer = Task { [weak self, timing] in
                    do { try await Self.sleep(timing.readyTimeout) } catch { return }
                    await self?.failConnection(generation: expected, error: GatewayTransportError.readyTimedOut)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.failConnection(generation: expected, error: CancellationError()) }
        }
    }

    private func receiveFrames(from socket: any GatewaySocket, generation expected: UUID) async {
        do {
            while !Task.isCancelled {
                let text = try await socket.receive()
                guard generation == expected else { return }
                try handleFrame(text, generation: expected)
            }
        } catch {
            guard generation == expected else { return }
            await failConnection(generation: expected, error: GatewayTransportError.connectionFailed)
        }
    }

    private func handleFrame(_ text: String, generation expected: UUID) throws {
        let data = Data(text.utf8)
        let frame = try JSONDecoder().decode(JSONValue.self, from: data)
        let incomingID = try JSONDecoder().decode(FrameIdentity.self, from: data).id
        guard frame.objectValue != nil, frame["jsonrpc"]?.stringValue == "2.0" else {
            throw GatewayTransportError.invalidResponse
        }
        if let method = frame["method"]?.stringValue {
            let params = frame["params"] ?? .object([:])
            if let id = incomingID {
                deliverServerRequest(id: id, method: method, params: params)
            } else if method == "event" {
                let event = try GatewayEvent(params: params)
                if event.type == "gateway.ready" {
                    sawReady = true
                    heartbeatSupported = event.payload["heartbeat"]?.boolValue == true
                    readyTimer?.cancel()
                    readyTimer = nil
                    let waiter = readyWaiter
                    readyWaiter = nil
                    waiter?.resume()
                } else if event.type == "request.cancel", let id = parsedID(event.payload["id"]) {
                    serverRequests.remove(id)
                }
                publish(.event(event))
            }
            return
        }
        guard let id = incomingID, pending[id] != nil else { return }
        if let error = frame["error"], error.objectValue != nil {
            let rpcError = JSONRPCError(code: error["code"]?.intValue ?? -32603,
                                       message: error["message"]?.stringValue ?? "Gateway request failed",
                                       data: error["data"])
            finishPending(id, generation: expected, result: .failure(rpcError))
        } else if let result = frame["result"] {
            if let method = pending[id]?.method, ["session.create", "session.resume", "session.activate"].contains(method) {
                publish(.snapshot(method: method, result: result))
            }
            // Snapshot questions follow the ordered snapshot marker, before resuming
            // the RPC caller. Re-emit known IDs so partial batch answers refresh.
            for request in result["open_requests"]?.arrayValue ?? [] {
                if let id = parsedID(request["id"]), let method = request["method"]?.stringValue {
                    deliverServerRequest(id: id, method: method, params: request["params"] ?? .object([:]), replay: true)
                }
            }
            finishPending(id, generation: expected, result: .success(result))
        } else {
            finishPending(id, generation: expected, result: .failure(GatewayTransportError.invalidResponse))
        }
    }

    private func deliverServerRequest(id: RPCID, method: String, params: JSONValue, replay: Bool = false) {
        let isNew = serverRequests.insert(id).inserted
        guard isNew || replay else { return }
        publish(.request(GatewayServerRequest(id: id, method: method, params: params)))
    }

    private func sendRequest(_ frame: OutboundFrame, id: RPCID, generation expected: UUID) async {
        guard generation == expected, pending[id] != nil, let socket else { return }
        do { try await socket.send(try encoded(frame)) }
        catch { await failConnection(generation: expected, error: GatewayTransportError.connectionFailed) }
    }

    private func finishPending(_ id: RPCID, generation expected: UUID, result: Result<JSONValue, Error>) {
        guard generation == expected, let call = pending.removeValue(forKey: id) else { return }
        call.timer.cancel()
        call.continuation.resume(with: result)
    }

    private func startHeartbeat(generation expected: UUID) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self, timing] in
            while !Task.isCancelled {
                do { try await Self.sleep(timing.heartbeatInterval) } catch { return }
                guard let self else { return }
                do { try await self.sendHeartbeat(generation: expected) }
                catch {
                    await self.failConnection(generation: expected, error: GatewayTransportError.connectionFailed)
                    return
                }
            }
        }
    }

    private func sendHeartbeat(generation expected: UUID) async throws {
        try checkGeneration(expected)
        _ = try await request("gateway.ping", timeout: timing.heartbeatTimeout)
    }

    private func failConnection(generation expected: UUID, error: Error) async {
        guard generation == expected else { return }
        let oldSocket = socket
        generation = UUID() // Retire before awaiting close; late frames cannot affect a new dial.
        socket = nil
        clearConnection(error: error)
        publish(.disconnected(error is CancellationError ? nil : error.localizedDescription))
        await oldSocket?.close()
    }

    private func clearConnection(error: Error) {
        isConnected = false
        sawReady = false
        heartbeatSupported = false
        receiver?.cancel(); receiver = nil
        heartbeat?.cancel(); heartbeat = nil
        readyTimer?.cancel(); readyTimer = nil
        let waiter = readyWaiter; readyWaiter = nil
        waiter?.resume(throwing: error)
        let calls = pending.values
        pending.removeAll()
        for call in calls {
            call.timer.cancel()
            call.continuation.resume(throwing: error)
        }
        serverRequests.removeAll()
    }

    private func checkGeneration(_ expected: UUID) throws {
        guard generation == expected else { throw GatewayTransportError.connectionChanged }
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func publish(_ update: GatewayUpdate) {
        var overflowed = false
        for stream in subscribers.values {
            if case .dropped = stream.yield(update) { overflowed = true }
        }
        // A stalled consumer must not silently lose transcript events or grow memory forever.
        // Keep the terminal disconnect marker in the bounded stream and require rehydration.
        if overflowed, socket != nil {
            let expected = generation
            Task { [weak self] in
                await self?.failConnection(generation: expected, error: GatewayTransportError.consumerTooSlow)
            }
        }
    }
    private func encoded<Value: Encodable>(_ value: Value) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private func parsedID(_ value: JSONValue?) -> RPCID? {
        if let text = value?.stringValue { return .string(text) }
        if let integer = value?.intValue { return .number(integer) }
        return nil
    }
    private static func sleep(_ interval: TimeInterval) async throws {
        let seconds = interval.isFinite ? min(max(interval, 0.001), 86_400) : 30
        try await Task.sleep(for: .seconds(seconds))
    }
}
