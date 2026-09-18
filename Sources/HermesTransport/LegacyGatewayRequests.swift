import Foundation
import HermesProtocol

/// Hermes before server-to-client JSON-RPC requests used named request events
/// and separate reply RPCs. Keep that compatibility at the transport boundary.
struct LegacyGatewayReply: Sendable, Equatable {
    let method: String
    let params: JSONValue
    let sessionID: String
}

enum LegacyGatewayRequestError: Error, LocalizedError, Equatable {
    case malformedPrompt
    case invalidAnswer
    case tooManyPrompts
    case pendingPromptCannotBeRestored
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .malformedPrompt:
            "This older Hermes gateway sent an incomplete permission or input request. Reconnect before continuing."
        case .invalidAnswer:
            "That answer is not allowed by the current Hermes request."
        case .tooManyPrompts:
            "Too many Hermes questions are pending. Reconnect to refresh the session."
        case .pendingPromptCannotBeRestored:
            "This older Hermes gateway cannot restore the input request waiting in this conversation. Resolve or stop it in the original client, or wait for it to expire, then reconnect."
        case .invalidReply:
            "Hermes did not confirm the answer. Reconnect to check the current request; the answer will not be sent again automatically."
        }
    }
}

struct LegacyGatewayRequests: Sendable {
    private struct Entry: Sendable {
        let request: GatewayServerRequest
        let sessionID: String
        let requestID: String
    }

    private var entries: [RPCID: Entry] = [:]
    private var retired: Set<RPCID> = []
    private var retiredOrder: [RPCID] = []
    private static let kinds: Set<String> = ["approval", "clarify", "sudo", "secret"]

    /// Additional updates to publish after the original event. No RPC is sent
    /// here, and merely presenting/acknowledging an approval never grants it.
    mutating func receive(event: GatewayEvent) throws -> [GatewayUpdate] {
        if event.type.hasSuffix(".request") {
            let kind = String(event.type.dropLast(".request".count))
            guard Self.kinds.contains(kind) else { return [] }
            if let update = try register(kind: kind, sessionID: event.sessionID, payload: event.payload) { return [update] }
            return []
        }
        if event.type.hasSuffix(".expire") {
            let kind = String(event.type.dropLast(".expire".count))
            guard Self.kinds.contains(kind), let session = event.sessionID,
                  let requestID = event.payload["request_id"]?.stringValue,
                  !session.isEmpty, session.utf8.count <= 1_024,
                  !requestID.isEmpty, requestID.utf8.count <= 1_024 else { return [] }
            let updates = cancel { $0.sessionID == session && $0.requestID == requestID && $0.request.method == kind }
            // An expiration can precede a slow snapshot/query response even
            // when this client never received the original prompt event.
            retire(Self.identifier(kind: kind, sessionID: session, requestID: requestID))
            return updates
        }
        if ["message.complete", "session.closed", "session.reclaimed"].contains(event.type),
           let session = event.sessionID {
            return cancel { $0.sessionID == session }
        }
        return []
    }

    /// Older snapshots replay only approvals and clarifications. They cannot
    /// restore sudo/secret prompts, so never imply that a waiting session is ready.
    mutating func replay(snapshot: JSONValue) throws -> [GatewayUpdate] {
        let session = snapshot["session_id"]?.stringValue
        var updates: [GatewayUpdate] = []
        var containsReplayablePrompt = false
        for (field, kind) in [("pending_approval", "approval"), ("pending_clarify", "clarify")] {
            if let payload = snapshot[field], payload != .null {
                if let update = try register(kind: kind, sessionID: session, payload: payload) { updates.append(update) }
                containsReplayablePrompt = true
            }
        }
        if snapshot["status"]?.stringValue == "waiting", !containsReplayablePrompt,
           !entries.values.contains(where: { $0.sessionID == session }) {
            throw LegacyGatewayRequestError.pendingPromptCannotBeRestored
        }
        return updates
    }

    /// Read after a legacy session snapshot and after an approval answer: old
    /// snapshots contain only the oldest approval even when several are pending.
    static func approvalsQuery(sessionID: String) -> LegacyGatewayReply {
        LegacyGatewayReply(method: "approval.pending", params: .object([
            "session_id": .string(sessionID)
        ]), sessionID: sessionID)
    }

    mutating func replayApprovals(sessionID: String, result: JSONValue) throws -> [GatewayUpdate] {
        guard let approvals = result["approvals"]?.arrayValue else {
            throw LegacyGatewayRequestError.malformedPrompt
        }
        guard approvals.count <= 256 else { throw LegacyGatewayRequestError.tooManyPrompts }
        // Positive replay only: a newer event may arrive while the read is in
        // flight, so absence in this response cannot revoke that newer request.
        return try approvals.compactMap { try register(kind: "approval", sessionID: sessionID, payload: $0) }
    }

    func acknowledgement(for id: RPCID) -> LegacyGatewayReply? {
        guard let entry = entries[id], entry.request.method == "approval" else { return nil }
        return LegacyGatewayReply(method: "approval.received", params: .object([
            "session_id": .string(entry.sessionID), "request_id": .string(entry.requestID)
        ]), sessionID: entry.sessionID)
    }

    /// A nil result means this is not one of this connection's legacy IDs.
    /// Keep the entry until the reply RPC settles; transport failures must not
    /// retry an answer whose delivery is uncertain.
    func response(to id: RPCID, result: JSONValue) throws -> LegacyGatewayReply? {
        guard let entry = entries[id] else { return nil }
        guard result.objectValue != nil else { throw LegacyGatewayRequestError.invalidAnswer }
        var params: [String: JSONValue] = ["session_id": .string(entry.sessionID),
                                          "request_id": .string(entry.requestID)]
        switch entry.request.method {
        case "approval":
            guard let choice = result["choice"]?.stringValue,
                  entry.request.params["choices"]?.arrayValue?.contains(.string(choice)) == true else {
                throw LegacyGatewayRequestError.invalidAnswer
            }
            params["choice"] = .string(choice)
            params["all"] = .bool(false)
        case "clarify":
            if let questions = entry.request.params["questions"]?.arrayValue, !questions.isEmpty {
                if result.objectValue?.isEmpty == true {
                    params["answer"] = .string("")
                } else {
                    let qids = Set(questions.compactMap { $0["qid"]?.stringValue })
                    guard let answers = result["answers"]?.objectValue,
                          Set(answers.keys) == qids,
                          answers.values.allSatisfy({ $0.stringValue != nil }) else {
                        throw LegacyGatewayRequestError.invalidAnswer
                    }
                    let data = try JSONEncoder().encode(JSONValue.object(["answers": .object(answers)]))
                    params["answer"] = .string(String(decoding: data, as: UTF8.self))
                }
            } else {
                guard let answer = result["answer"]?.stringValue else {
                    throw LegacyGatewayRequestError.invalidAnswer
                }
                params["answer"] = .string(answer)
            }
        case "sudo", "secret":
            guard let value = result["value"]?.stringValue else {
                throw LegacyGatewayRequestError.invalidAnswer
            }
            params[entry.request.method == "sudo" ? "password" : "value"] = .string(value)
        default:
            throw LegacyGatewayRequestError.invalidAnswer
        }
        return LegacyGatewayReply(method: entry.request.method + ".respond", params: .object(params),
                                  sessionID: entry.sessionID)
    }

    func rejection(to id: RPCID) -> LegacyGatewayReply? {
        guard let entry = entries[id] else { return nil }
        let result: JSONValue
        switch entry.request.method {
        case "approval": result = .object(["choice": .string("deny")])
        case "clarify":
            result = entry.request.params["questions"]?.arrayValue?.isEmpty == false
                ? .object([:]) : .object(["answer": .string("")])
        default: result = .object(["value": .string("")])
        }
        return try? response(to: id, result: result)
    }

    func validateReply(result: JSONValue, for reply: LegacyGatewayReply) throws {
        if reply.method == "approval.respond" {
            guard let resolved = result["resolved"]?.intValue, resolved >= 0 else {
                throw LegacyGatewayRequestError.invalidReply
            }
        } else if ["clarify.respond", "sudo.respond", "secret.respond"].contains(reply.method) {
            guard let status = result["status"]?.stringValue, ["ok", "expired"].contains(status) else {
                throw LegacyGatewayRequestError.invalidReply
            }
        } else {
            throw LegacyGatewayRequestError.invalidReply
        }
    }

    mutating func settle(_ id: RPCID) {
        entries.removeValue(forKey: id)
        retire(id)
    }

    private mutating func register(kind: String, sessionID: String?, payload: JSONValue) throws -> GatewayUpdate? {
        guard let sessionID, !sessionID.isEmpty, sessionID.utf8.count <= 1_024,
              let requestID = payload["request_id"]?.stringValue, !requestID.isEmpty,
              requestID.utf8.count <= 1_024, var params = payload.objectValue else {
            throw LegacyGatewayRequestError.malformedPrompt
        }
        // The length-delimited session component prevents separator collisions.
        let id = Self.identifier(kind: kind, sessionID: sessionID, requestID: requestID)
        guard !retired.contains(id) else { return nil }
        guard entries[id] != nil || entries.count < 256 else {
            throw LegacyGatewayRequestError.tooManyPrompts
        }
        params["session_id"] = .string(sessionID)
        if kind == "approval" {
            var defaultChoices = ["once", "deny"]
            // Match the remote _approval_request_payload flags when a raw
            // approval.pending row does not already carry explicit choices.
            if params["allow_permanent"]?.boolValue == false { defaultChoices = ["once", "session", "deny"] }
            else if params["allow_permanent"]?.boolValue == true { defaultChoices = ["once", "session", "always", "deny"] }
            var allowed = Set(params["choices"]?.arrayValue?.compactMap(\.stringValue) ?? defaultChoices)
            allowed.formIntersection(["once", "session", "always", "deny"])
            allowed.insert("deny")
            if params["smart_denied"]?.boolValue == true { allowed.formIntersection(["once", "deny"]) }
            if params["allow_session"]?.boolValue == false { allowed.remove("session") }
            if params["allow_permanent"]?.boolValue == false { allowed.remove("always") }
            // approval.pending returns raw entries, sometimes without choices.
            // Explicit flags permit only their own scope; absent flags never do.
            if params["choices"] == nil, params["smart_denied"]?.boolValue != true {
                if params["allow_session"]?.boolValue == true { allowed.insert("session") }
                if params["allow_permanent"]?.boolValue == true { allowed.insert("always") }
            }
            params["choices"] = .array(["once", "session", "always", "deny"].filter(allowed.contains).map(JSONValue.string))
        }
        let request = GatewayServerRequest(id: id, method: kind, params: .object(params))
        entries[id] = Entry(request: request, sessionID: sessionID, requestID: requestID)
        return .request(request)
    }

    private mutating func cancel(where matches: (Entry) -> Bool) -> [GatewayUpdate] {
        let cancelled = entries.values.filter(matches)
        return cancelled.map { entry in
            entries.removeValue(forKey: entry.request.id)
            retire(entry.request.id)
            let id: JSONValue
            switch entry.request.id {
            case .string(let value): id = .string(value)
            case .number(let value): id = .number(Double(value))
            }
            return .event(GatewayEvent(type: "request.cancel", sessionID: entry.sessionID,
                                       payload: .object(["id": id])))
        }
    }

    private mutating func retire(_ id: RPCID) {
        guard retired.insert(id).inserted else { return }
        retiredOrder.append(id)
        // Retain IDs only (never answers or prompt contents), bounded per
        // connection. Every legacy reply still includes the original request ID.
        if retiredOrder.count > 4_096 {
            retired.remove(retiredOrder.removeFirst())
        }
    }

    private static func identifier(kind: String, sessionID: String, requestID: String) -> RPCID {
        .string("legacy:\(kind):\(sessionID.utf8.count):\(sessionID):\(requestID)")
    }
}
