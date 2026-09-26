import Foundation
import HermesProtocol
import HermesTransport

public struct MobileSchedule: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let promptPreview: String
    public let schedule: String
    public let enabled: Bool
    public let lastRunAt: Date?
    public let nextRunAt: Date?
    public let lastStatus: String?

    init?(json: JSONValue) {
        guard let id = activityID(json["id"] ?? json["job_id"]) else { return nil }
        self.id = id
        name = activityText(json["name"], fallback: "Automation", limit: 200)
        promptPreview = activityText(json["prompt_preview"] ?? json["prompt"], limit: 500)
        if let text = json["schedule"]?.stringValue { schedule = String(text.prefix(200)) }
        else { schedule = activityText(json["schedule_display"] ?? json["schedule"]?["display"], limit: 200) }
        enabled = json["enabled"]?.boolValue ?? true
        lastRunAt = activityDate(json["last_run_at"])
        nextRunAt = activityDate(json["next_run_at"])
        lastStatus = json["last_status"]?.stringValue.map { String($0.prefix(200)) }
    }
}

public struct MobileRun: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: StoredSessionID
    public let scheduleID: String
    public let title: String
    /// Actual assistant output. Empty when the bounded history page has no reply.
    public var summary: String
    public let startedAt: Date?
    public let isActive: Bool
    public let endedAt: Date?
    public let endReason: String?
    public var status: AutomationRunStatus
    public var automationID: String { scheduleID }

    init?(json: JSONValue, schedule: MobileSchedule, profile: String) {
        guard let id = activityID(json["id"]),
              json["profile"]?.stringValue.map({ $0 == profile }) != false else { return nil }
        self.id = id; sessionID = StoredSessionID(rawValue: id); scheduleID = schedule.id
        title = activityText(json["title"], fallback: schedule.name, limit: 250)
        summary = ""
        startedAt = activityDate(json["started_at"])
        isActive = json["is_active"]?.boolValue ?? false
        endedAt = activityDate(json["ended_at"])
        endReason = json["end_reason"]?.stringValue
        status = isActive ? .working : endReason == "cron_complete" ? .completed : .unavailable
        if ["error", "failed", "cron_failed"].contains(endReason ?? "") { status = .failed }
        if endReason == "cron_incomplete_no_output" { status = .noOutput }
    }
}

public struct MobileSkill: Identifiable, Equatable, Sendable {
    public let name: String
    public let category: String
    public var id: String { category + "\u{1f}" + name }
}

public struct MobileProject: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let folders: [String]
    public let primaryPath: String?

    init?(json: JSONValue) {
        guard let id = activityID(json["id"]), json["archived"]?.boolValue != true else { return nil }
        self.id = id
        name = activityText(json["name"], fallback: "Project", limit: 200)
        primaryPath = json["primary_path"]?.stringValue.map { String($0.prefix(2_048)) }
        folders = (json["folders"]?.arrayValue ?? []).prefix(50).compactMap { row in
            guard let path = row["path"]?.stringValue, !path.isEmpty else { return nil }
            return String(path.prefix(2_048))
        }
    }
}

public struct MobileActivitySnapshot: Equatable, Sendable {
    public var schedules: [MobileSchedule]
    public var runs: [MobileRun]
    public var skills: [MobileSkill]
    public var projects: [MobileProject]
    public var notices: [String]

    public init(schedules: [MobileSchedule] = [], runs: [MobileRun] = [], skills: [MobileSkill] = [],
                projects: [MobileProject] = [], notices: [String] = []) {
        self.schedules = schedules; self.runs = runs; self.skills = skills
        self.projects = projects; self.notices = notices
    }
}

public struct MobilePendingInput: Identifiable, Equatable, Sendable {
    public let input: PendingInput
    /// Nil until an authoritative session snapshot resolves this request's owner.
    public let sessionID: StoredSessionID?
    public let title: String
    public var id: String { String(describing: input.id) }

    init(input: PendingInput, state: ConversationState?) {
        self.input = input; sessionID = state?.storedID
        title = state?.title ?? activityText(input.params["description"], fallback: "Hermes needs your answer", limit: 200)
    }
}

public typealias MobileActivityLoader = @Sendable (GatewayClient, GatewayEndpoint, GatewaySession) async throws -> MobileActivitySnapshot

/// A bounded, read-only view of the host's schedules, run output and installed
/// skills. Failures remain visible; sample content is never substituted.
public struct MobileActivityService: Sendable {
    public typealias RPC = @Sendable (String, JSONValue) async throws -> JSONValue
    public typealias Read = @Sendable (GatewayReadEndpoint) async throws -> JSONValue
    private let request: RPC
    private let read: Read
    public static let maximumSchedules = 16
    public static let maximumRuns = 40
    public static let maximumSummaries = 12

    public init(client: GatewayClient, reader: GatewayReader) {
        request = { try await client.request($0, params: $1) }
        read = { try await reader.read($0) }
    }

    public init(request: @escaping RPC, read: @escaping Read) {
        self.request = request; self.read = read
    }

    public func load(profile: String) async throws -> MobileActivitySnapshot {
        var snapshot = MobileActivitySnapshot()
        var succeeded = 0
        let params = JSONValue.object(["profile": .string(profile), "action": .string("list")])
        // Three independent domains tolerate an older gateway that supports only
        // some of the read APIs. Every domain still uses the same explicit owner.
        do {
            let result = try await read(.schedules)
            guard let rows = result.arrayValue else { throw MobileActivityError.invalidResponse }
            var seen = Set<String>()
            snapshot.schedules = rows.filter { $0["profile"]?.stringValue.map({ $0 == profile }) != false }
                .compactMap(MobileSchedule.init).filter { seen.insert($0.id).inserted }
            if snapshot.schedules.count > Self.maximumSchedules {
                snapshot.notices.append("Showing recent runs for the first \(Self.maximumSchedules) automations.")
            }
            snapshot.schedules = Array(snapshot.schedules.prefix(200))
            succeeded += 1
        } catch {
            try Task.checkCancellation()
            snapshot.notices.append("Automations could not be loaded. Pull to refresh.")
        }
        try Task.checkCancellation()
        do {
            let result = try await request("skills.manage", params)
            guard let categories = result["skills"]?.objectValue else { throw MobileActivityError.invalidResponse }
            var seen = Set<String>()
            for category in categories.keys.sorted().prefix(100) {
                for name in (categories[category]?.arrayValue ?? []).compactMap(\.stringValue).prefix(200) where !name.isEmpty {
                    let skill = MobileSkill(name: String(name.prefix(200)), category: String(category.prefix(100)))
                    if seen.insert(skill.id).inserted { snapshot.skills.append(skill) }
                    if snapshot.skills.count >= 500 { break }
                }
                if snapshot.skills.count >= 500 { break }
            }
            succeeded += 1
        } catch {
            try Task.checkCancellation()
            snapshot.notices.append("Installed skills could not be loaded. Pull to refresh.")
        }
        do {
            let result = try await request("projects.list", .object(["profile": .string(profile)]))
            guard let rows = result["projects"]?.arrayValue else { throw MobileActivityError.invalidResponse }
            var seen = Set<String>()
            snapshot.projects = Array(rows.compactMap(MobileProject.init).filter { seen.insert($0.id).inserted }.prefix(100))
            succeeded += 1
        } catch {
            try Task.checkCancellation()
            snapshot.notices.append("Project folders could not be loaded. Pull to refresh.")
        }
        guard succeeded > 0 else { throw MobileActivityError.unavailable }
        for schedule in snapshot.schedules.prefix(Self.maximumSchedules) {
            try Task.checkCancellation()
            do {
                let result = try await read(.scheduleRuns(id: schedule.id, limit: 5))
                guard let rows = result["runs"]?.arrayValue else { throw MobileActivityError.invalidResponse }
                snapshot.runs += rows.prefix(5).compactMap { MobileRun(json: $0, schedule: schedule, profile: profile) }
            } catch {
                try Task.checkCancellation()
                if !snapshot.notices.contains("Some automation runs could not be loaded.") {
                    snapshot.notices.append("Some automation runs could not be loaded.")
                }
            }
        }
        var seenRuns = Set<String>()
        snapshot.runs = Array(snapshot.runs.sorted {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }.filter { seenRuns.insert($0.id).inserted }.prefix(Self.maximumRuns))
        for index in snapshot.runs.indices.prefix(Self.maximumSummaries) {
            try Task.checkCancellation()
            do {
                let result = try await read(.sessionMessages(id: snapshot.runs[index].sessionID.rawValue, limit: 20))
                guard result["profile"]?.stringValue.map({ $0 == profile }) != false,
                      result["session_id"]?.stringValue.map({ $0 == snapshot.runs[index].sessionID.rawValue }) != false,
                      result["messages"]?.arrayValue != nil else { throw MobileActivityError.invalidResponse }
                let detail = AutomationRunResult.parse(snapshot.runs[index], response: result)
                snapshot.runs[index].summary = String(detail.result.prefix(1_200))
                snapshot.runs[index].status = detail.status
            } catch {
                try Task.checkCancellation()
                if !snapshot.notices.contains("Some run results are unavailable; open the run to retry.") {
                    snapshot.notices.append("Some run results are unavailable; open the run to retry.")
                }
            }
        }
        return snapshot
    }
}

public enum MobileActivityError: Error, LocalizedError, Sendable {
    case invalidResponse, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The gateway returned an invalid activity response."
        case .unavailable: "Activity could not be loaded from this gateway. Pull to refresh."
        }
    }
}

private func activityID(_ value: JSONValue?) -> String? {
    guard let id = value?.stringValue, !id.isEmpty, id.utf8.count <= 512 else { return nil }
    return id
}

private func activityText(_ value: JSONValue?, fallback: String = "", limit: Int) -> String {
    guard let text = value?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
    return String(text.prefix(limit))
}

private func activityDisplayText(_ row: JSONValue) -> String {
    // REST intentionally retains a compaction carrier's physical content for
    // inspection/export. Its display projection is authoritative even when
    // empty or null, so never fall back to model-facing content in that case.
    if let projection = row["display_content"] { return projection.stringValue ?? "" }
    return row["content"]?.stringValue ?? row["text"]?.stringValue ?? ""
}

private func activityDate(_ value: JSONValue?) -> Date? {
    if case .number(let seconds) = value, seconds.isFinite, seconds > 0, seconds < 253_402_300_800 {
        return Date(timeIntervalSince1970: seconds)
    }
    if let text = value?.stringValue {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
    return nil
}
