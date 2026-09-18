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
                .task { await connectDesignFixtureIfRequested() }
                #endif
        }
            .onChange(of: phase) { _, phase in
                if phase == .background {
                    model.persistDrafts()
                    returnedFromBackground = true
                }
                // Resume with authoritative history after suspension; never resend a prompt.
                if phase == .active, returnedFromBackground, model.endpoint != nil, !model.isConnecting {
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
        await model.connect(to: GatewayEndpoint(name: "Design preview", baseURL: url), token: token, remember: false)
        if let session = env["TALARIA_DESIGN_SESSION"], model.isConnected {
            await model.openSession(StoredSessionID(rawValue: session))
        }
    }
    #endif
}
