import Foundation
import HermesProtocol
import HermesTransport
import HermesCore
import HermesMacServices

private actor EventProbe {
    var events: [GatewayEvent] = []
    var inputs: [GatewayServerRequest] = []
    func record(_ update: GatewayUpdate) {
        if case .event(let event) = update { events.append(event) }
        if case .request(let request) = update { inputs.append(request) }
    }
    func completed(_ session: String) -> GatewayEvent? {
        events.last { $0.type == "message.complete" && $0.sessionID == session }
    }
    func completionCount(_ session: String) -> Int {
        events.filter { $0.type == "message.complete" && $0.sessionID == session }.count
    }
    func counts() -> [String: Int] { Dictionary(grouping: events, by: \.type).mapValues(\.count) }
}

@main
struct HermesSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        func argument(_ name: String, default value: String) -> String {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return value }
            return args[index + 1]
        }
        if args.contains("--help") {
            print("""
            hermes-smoke --url URL [--profile default] [--prompt TEXT]
              Set HERMES_GATEWAY_TOKEN in the environment.
            hermes-smoke --launch-python PATH --launch-home PATH --launch-cwd PATH [--profile default]
              Launch and stop an owned local runtime with a generated token.
            Both modes create one session and send one prompt.
            Add --extended --fixture-directory PATH for isolated model/profile/attachment checks.
            """)
            return
        }
        let profile = argument("--profile", default: "default")
        let client = GatewayClient()
        let manager = LocalRuntimeManager()
        var ownedRuntimeURL: URL?
        var token = ""
        let probe = EventProbe()
        let updates = await client.updates()
        let receiver = Task { for await update in updates { await probe.record(update) } }
        defer { receiver.cancel() }
        do {
            let url: URL
            if args.contains("--launch-python") {
                guard !args.contains("--url") else { throw SmokeError.failure("Choose --url or --launch-python.") }
                let python = argument("--launch-python", default: "")
                let home = argument("--launch-home", default: "")
                let cwd = argument("--launch-cwd", default: "")
                guard !python.isEmpty, !home.isEmpty, !cwd.isEmpty else {
                    throw SmokeError.failure("Local launch requires --launch-python, --launch-home and --launch-cwd.")
                }
                let running = try await manager.start(LocalRuntimeConfiguration(
                    executableURL: URL(fileURLWithPath: python), arguments: ["-m", "hermes_cli.main"],
                    hermesHome: URL(fileURLWithPath: home), profile: profile,
                    workingDirectory: URL(fileURLWithPath: cwd)
                ))
                url = running.baseURL
                token = running.token
                ownedRuntimeURL = url
            } else {
                guard let credential = ProcessInfo.processInfo.environment["HERMES_GATEWAY_TOKEN"], !credential.isEmpty else {
                    throw SmokeError.failure("Set HERMES_GATEWAY_TOKEN; credentials are never accepted as command-line arguments.")
                }
                guard let endpointURL = URL(string: argument("--url", default: "http://127.0.0.1:8642")) else {
                    throw SmokeError.failure("Invalid gateway URL.")
                }
                token = credential
                url = endpointURL
            }
            let endpoint = GatewayEndpoint(name: "Smoke test", baseURL: url, profile: profile)
            try await client.connect(to: endpoint, token: token)
            let snapshot = try await client.request("session.create", params: .object([
                "profile": .string(profile), "source": .string("native"), "title": .string("Native integration smoke")
            ]), timeout: 90)
            let state = try ConversationState(snapshot: snapshot, owner: .init(connectionID: endpoint.id, profile: profile))
            let runtime = state.runtimeID.rawValue
            _ = try await client.request("prompt.submit", params: .object([
                "session_id": .string(runtime), "profile": .string(profile),
                "text": .string(argument("--prompt", default: "Say hello to the native Hermes client."))
            ]), timeout: 90)
            let deadline = Date().addingTimeInterval(90)
            while await probe.completed(runtime) == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let completed = await probe.completed(runtime) else { throw SmokeError.failure("No message.complete within 90 seconds") }
            guard completed.payload["status"]?.stringValue != "error", completed.payload["error"]?.stringValue == nil else {
                throw SmokeError.failure("Hermes reported a failed turn")
            }
            let list = try await client.request("session.list", params: .object(["profile": .string(profile), "limit": .number(100)]))
            guard let session = list["sessions"]?.arrayValue?.first(where: { $0["id"]?.stringValue == state.storedID.rawValue })
                ?? list["sessions"]?.arrayValue?.first(where: { $0["title"]?.stringValue == "Native integration smoke" }),
                let stored = session["id"]?.stringValue else { throw SmokeError.failure("Created session missing from session.list") }
            await client.disconnect()
            try await client.connect(to: endpoint, token: token)
            let resumed = try await client.request("session.resume", params: .object([
                "session_id": .string(stored), "profile": .string(profile), "source": .string("native")
            ]), timeout: 90)
            let hydrated = try ConversationState(snapshot: resumed, owner: state.owner)
            guard hydrated.messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) else {
                throw SmokeError.failure("Reconnect history has no assistant response")
            }
            var extended: [String: JSONValue] = [:]
            if args.contains("--extended") {
                let fixtureDirectory = argument("--fixture-directory", default: "")
                guard !fixtureDirectory.isEmpty else { throw SmokeError.failure("Extended checks require a fixture directory.") }
                extended = try await runExtended(client: client, endpoint: endpoint, token: token,
                    probe: probe, snapshot: resumed, state: hydrated,
                    fixtureDirectory: URL(fileURLWithPath: fixtureDirectory))
            }
            let counts = await probe.counts()
            await client.disconnect()
            if let ownedRuntimeURL {
                await manager.stop()
                try await assertOwnedRuntimeStopped(at: ownedRuntimeURL)
            }
            let result: JSONValue = .object([
                "passed": .bool(true), "reconnected": .bool(true),
                "native_runtime": .bool(ownedRuntimeURL != nil),
                "runtime_stopped": .bool(ownedRuntimeURL != nil),
                "extended_passed": .bool(!extended.isEmpty),
                "extended": .object(extended),
                "history_messages": .number(Double(hydrated.messages.count)),
                "events": .object(counts.mapValues { .number(Double($0)) })
            ])
            print(ConversationState.describe(result))
        } catch {
            await client.disconnect()
            await manager.stop()
            let log = await manager.logTail()
            if !log.isEmpty { FileHandle.standardError.write(Data("Owned runtime diagnostic tail:\n\(log)\n".utf8)) }
            let message = token.isEmpty ? error.localizedDescription
                : error.localizedDescription.replacingOccurrences(of: token, with: "[redacted]")
            FileHandle.standardError.write(Data("Smoke failed: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func submitAndWait(_ text: String, sessionID: String, profile: String,
                                      client: GatewayClient, probe: EventProbe) async throws {
        let before = await probe.completionCount(sessionID)
        _ = try await client.request("prompt.submit", params: .object([
            "session_id": .string(sessionID), "profile": .string(profile), "text": .string(text)
        ]), timeout: 90)
        let deadline = Date().addingTimeInterval(90)
        while await probe.completionCount(sessionID) == before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard await probe.completionCount(sessionID) > before,
              let completion = await probe.completed(sessionID),
              completion.payload["status"]?.stringValue != "error", completion.payload["error"]?.stringValue == nil else {
            throw SmokeError.failure("Extended prompt did not complete successfully.")
        }
    }

    private static func runExtended(client: GatewayClient, endpoint: GatewayEndpoint, token: String,
                                    probe: EventProbe, snapshot: JSONValue, state: ConversationState,
                                    fixtureDirectory: URL) async throws -> [String: JSONValue] {
        let settings = GatewaySettingsService(client: client)
        let sessionID = state.runtimeID.rawValue
        let inventory = try await settings.load(profile: endpoint.profile, sessionID: sessionID, refresh: true)
        guard inventory.profiles.contains(where: { $0.name == "default" }),
              inventory.profiles.contains(where: { $0.name == "native-smoke-secondary" }),
              let provider = inventory.models.providers.first(where: { $0.matches("custom") }),
              provider.isAvailable, provider.models.contains("native-smoke-alternate") else {
            throw SmokeError.failure("Real settings inventory omitted the configured custom models or named profile.")
        }
        let selection = GatewayModelSelection(provider: "custom", model: "native-smoke-alternate")
        let change = try await settings.selectModel(selection, profile: endpoint.profile, sessionID: sessionID)
        guard !change.requiresConfirmation, !change.deferred, change.scope == "session" else {
            throw SmokeError.failure("Idle synthetic model selection did not apply to the live session.")
        }
        let current = try await settings.modelOptions(profile: endpoint.profile, sessionID: sessionID)
        guard current.model == selection.model else { throw SmokeError.failure("Model switch was not reflected by live inventory.") }
        do {
            _ = try await settings.selectModel(selection, profile: endpoint.profile, sessionID: "missing-\(UUID().uuidString)")
            throw SmokeError.failure("A stale session unexpectedly accepted a model mutation.")
        } catch let error as JSONRPCError where error.code == 4001 { /* required fail-closed response */ }
        let defaults = try await settings.modelOptions(profile: endpoint.profile)
        guard defaults.model == "native-smoke-model" else {
            throw SmokeError.failure("A session model change altered the profile default.")
        }

        guard let workspace = snapshot["info"]?["cwd"]?.stringValue, !workspace.isEmpty else {
            throw SmokeError.failure("Session snapshot did not include its host workspace.")
        }
        let scope = ComposerScope(owner: state.owner, sessionID: state.storedID)
        let document = try AttachmentLoader.stage(data: Data(contentsOf: fixtureDirectory.appendingPathComponent("native-smoke.txt")),
                                                 filename: "native-smoke.txt", scope: scope)
        let image = try AttachmentLoader.stage(data: Data(contentsOf: fixtureDirectory.appendingPathComponent("native-smoke.png")),
                                              filename: "native-smoke.png", scope: scope)
        let transfer = AttachmentTransferService()
        let uploadedDocument = try await transfer.upload(document, workspace: workspace, endpoint: endpoint, token: token)
        let uploadedImage = try await transfer.upload(image, workspace: workspace, endpoint: endpoint, token: token)
        let imageResult = try await client.request("image.attach", params: .object([
            "session_id": .string(sessionID), "profile": .string(endpoint.profile), "path": .string(uploadedImage.hostPath)
        ]))
        guard imageResult["attached"]?.boolValue == true, imageResult["count"]?.intValue == 1 else {
            throw SmokeError.failure("The uploaded image was not queued exactly once for this session.")
        }
        let prompt = try AttachmentPrompt.compose(text: "NATIVE_ATTACHMENT_CHECK inspect the attached document and image.",
                                                  attachments: [uploadedDocument, uploadedImage], scope: scope)
        try await submitAndWait(prompt, sessionID: sessionID, profile: endpoint.profile, client: client, probe: probe)
        await client.disconnect()
        try await client.connect(to: endpoint, token: token)
        let rehydrated = try await client.request("session.resume", params: .object([
            "session_id": .string(state.storedID.rawValue), "profile": .string(endpoint.profile), "source": .string("native")
        ]), timeout: 90)
        let attachmentHistory = try ConversationState(snapshot: rehydrated, owner: state.owner)
        guard attachmentHistory.messages.contains(where: { $0.role == .assistant && $0.text.contains("TALARIA_ATTACHMENTS_CONFIRMED") }),
              attachmentHistory.messages.contains(where: { $0.role == .user && $0.text.contains("@file:") && $0.text.contains("native-smoke.txt") }),
              attachmentHistory.messages.contains(where: { $0.role == .user && $0.text.contains(uploadedImage.hostPath) }) else {
            throw SmokeError.failure("Reconnect did not preserve document/image history and verified inference response.")
        }
        let detached = try await client.request("image.detach", params: .object([
            "session_id": .string(attachmentHistory.runtimeID.rawValue), "profile": .string(endpoint.profile),
            "path": .string(uploadedImage.hostPath)
        ]))
        guard detached["count"]?.intValue == 0, detached["detached"]?.boolValue == false else {
            throw SmokeError.failure("The image remained queued after its completed turn.")
        }

        let namedProfile = "native-smoke-secondary"
        let otherEndpoint = GatewayEndpoint(name: "Named profile fixture", baseURL: endpoint.baseURL, profile: namedProfile)
        let other = GatewayClient()
        let otherProbe = EventProbe()
        let otherUpdates = await other.updates()
        let otherReceiver = Task { for await update in otherUpdates { await otherProbe.record(update) } }
        defer { otherReceiver.cancel() }
        do {
            try await other.connect(to: otherEndpoint, token: token)
            let created = try await other.request("session.create", params: .object([
                "profile": .string(namedProfile), "source": .string("native"), "title": .string("Native named profile smoke")
            ]), timeout: 90)
            let named = try ConversationState(snapshot: created, owner: .init(connectionID: otherEndpoint.id, profile: namedProfile))
            let namedModels = try await GatewaySettingsService(client: other).modelOptions(profile: namedProfile, sessionID: named.runtimeID.rawValue)
            guard namedModels.model == "native-smoke-profile" else { throw SmokeError.failure("Named profile returned another profile's default model.") }
            try await submitAndWait("NATIVE_PROFILE_CHECK verify this profile's configured model.",
                                    sessionID: named.runtimeID.rawValue, profile: namedProfile, client: other, probe: otherProbe)
            let ownList = try await other.request("session.list", params: .object(["profile": .string(namedProfile)]))
            let defaultList = try await client.request("session.list", params: .object(["profile": .string(endpoint.profile)]))
            let namedRows = ownList["sessions"]?.arrayValue ?? []
            let defaultRows = defaultList["sessions"]?.arrayValue ?? []
            guard namedRows.contains(where: { $0["title"]?.stringValue == "Native named profile smoke" }),
                  !defaultRows.contains(where: { $0["title"]?.stringValue == "Native named profile smoke" }),
                  !namedRows.contains(where: { $0["title"]?.stringValue == "Native integration smoke" }) else {
                throw SmokeError.failure("Session history was not isolated by profile.")
            }
            await other.disconnect()
        } catch {
            await other.disconnect()
            throw error
        }
        return ["model_switch": .bool(true), "stale_model_rejected": .bool(true), "profile_defaults_preserved": .bool(true),
                "profile_routing": .bool(true), "document_ingestion": .bool(true), "image_ingestion": .bool(true),
                "attachment_history": .bool(true), "attachment_history_messages": .number(Double(attachmentHistory.messages.count))]
    }

    private static func assertOwnedRuntimeStopped(at baseURL: URL) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        request.timeoutInterval = 2
        do {
            _ = try await session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return
        }
        throw SmokeError.failure("The owned runtime still accepts HTTP after manager.stop().")
    }
}
private enum SmokeError: Error, LocalizedError {
    case failure(String)
    var errorDescription: String? { switch self { case .failure(let message): message } }
}
