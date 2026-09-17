import SwiftUI
import HermesCore
import HermesUI

@main
struct HermesIOSApp: App {
    @State private var model = HermesAppModel()
    @Environment(\.scenePhase) private var phase
    @State private var returnedFromBackground = false
    var body: some Scene {
        WindowGroup { HermesRootView(model: model) }
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
}
