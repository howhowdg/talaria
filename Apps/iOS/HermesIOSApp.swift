import SwiftUI
import HermesCore
import HermesUI
import HermesTransport

@main
struct HermesIOSApp: App {
    @State private var model = HermesAppModel()
    @Environment(\.scenePhase) private var phase
    @State private var returnedFromBackground = false
    var body: some Scene {
        WindowGroup {
            HermesRootView(model: model)
                #if DEBUG
                .modifier(DesignPreviewAppearance())
                .task { await connectDesignFixtureIfRequested() }
                #endif
        }
            .onChange(of: phase) { _, phase in
                if phase == .background {
                    model.persistDrafts()
                    returnedFromBackground = true
                }
                // Resume with authoritative history after suspension; never resend a prompt.
                if phase == .active, returnedFromBackground, model.desiredConnection, !model.isConnecting {
                    returnedFromBackground = false
                    Task { await model.reconnect() }
                }
            }
    }

    #if DEBUG
    /// Explicit simulator launch configuration for the synthetic visual fixture.
    /// Release builds contain neither this connection path nor preview routing.
    private func connectDesignFixtureIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard env["TALARIA_DESIGN_PREVIEW"] == "1", model.endpoint == nil,
              let raw = env["TALARIA_DESIGN_URL"], let url = URL(string: raw),
              url.scheme == "http", url.host == "127.0.0.1",
              let token = env["TALARIA_DESIGN_TOKEN"], !token.isEmpty else { return }
        let fixtureID = UUID(uuidString: "7DBFDE9E-503B-4D63-8C88-6AC61A78E0A4")!
        await model.connect(to: GatewayEndpoint(id: fixtureID, name: "Hermes", baseURL: url), token: token, remember: false)
        guard model.isConnected, let owner = model.currentHierarchyOwner,
              model.sessions.contains(where: { $0.id.rawValue == "design-home" }) else { return }
        // Only this explicit, synthetic owner is seeded. Production organisation
        // is never inferred from session names, recency, or source metadata.
        model.classificationStore.update(for: owner) { $0 = HierarchyClassification() }
        let travel = model.createWorkspace(name: "Plan a trip", purpose: "Lisbon, Oct 9–12, under €900.",
            swatch: "#3B7DDD", sessionID: StoredSessionID(rawValue: "design-lisbon-weekend"))
        let build = model.createWorkspace(name: "Build Talaria", purpose: "SwiftUI client for Hermes. Running tests.",
            swatch: "#858985", sessionID: StoredSessionID(rawValue: "design-downloads-review"))
        if let archived = model.createWorkspace(name: "Move apartment", purpose: "The move is complete.",
            swatch: "#858985", sessionID: StoredSessionID(rawValue: "design-sunday-notes")) {
            model.archiveWorkspace(archived)
        }
        await model.openSession(StoredSessionID(rawValue: "design-downloads-review"))
        await model.refreshMobileActivity()
        if env["TALARIA_DESIGN_HOME"] != "unselected" {
            await model.chooseHome(StoredSessionID(rawValue: "design-home"))
            model.recordLineage(child: StoredSessionID(rawValue: "design-lisbon-weekend"),
                                parent: StoredSessionID(rawValue: "design-home"), kind: .branch)
            if env["TALARIA_DESIGN_HOME"] == "unavailable" {
                model.classificationStore.update(for: owner) { $0.homeSessionID = StoredSessionID(rawValue: "design-missing-home") }
                await model.navigate(to: .home)
            }
        }
        let destination: HierarchyDestination
        switch env["TALARIA_DESIGN_DESTINATION"] {
        case "workspace": destination = travel.map(HierarchyDestination.workspace) ?? .workspaces
        case "approval": destination = build.map(HierarchyDestination.workspace) ?? .workspaces
        case "automation": destination = .automation("design-morning")
        case "run", "discuss": destination = .run("design-inbox-run")
        case "failed-run": destination = .run("design-project-run")
        case "no-output": destination = .run("design-empty-run")
        case "conversation": destination = .conversation(StoredSessionID(rawValue: "design-landlord"))
        default:
            switch env["TALARIA_DESIGN_TAB"] {
            case "Workspaces": destination = .workspaces
            case "Automations": destination = .automations
            case "Activity": destination = .activity
            default: destination = .home
            }
        }
        await model.navigate(to: destination)
        if env["TALARIA_DESIGN_DESTINATION"] == "activity-request", let request = model.mobilePendingInputs.first {
            await model.openActivityInput(request)
        }
    }
    #endif
}

#if DEBUG
/// Simulator preview appearance is process-scoped and never changes device settings.
private struct DesignPreviewAppearance: ViewModifier {
    @Environment(\.dynamicTypeSize) private var inheritedTypeSize
    func body(content: Content) -> some View {
        let env = ProcessInfo.processInfo.environment
        let preview = env["TALARIA_DESIGN_PREVIEW"] == "1"
        return content
            .preferredColorScheme(preview && env["TALARIA_DESIGN_APPEARANCE"] == "dark" ? .dark : nil)
            .environment(\.dynamicTypeSize,
                         preview && env["TALARIA_DESIGN_LARGE_TYPE"] == "1" ? .accessibility1 : inheritedTypeSize)
    }
}
#endif
