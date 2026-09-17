import SwiftUI
import AppKit
import HermesCore
import HermesUI
import HermesTransport
import HermesMacServices

@MainActor
final class MacCoordinator {
    static let shared = MacCoordinator()
    let model = HermesAppModel()
    let runtime = LocalRuntimeManager()

    func startLocal() async {
        guard let candidate = RuntimeDiscovery.candidates().first else {
            model.banner = "Hermes is not installed. Install the Hermes CLI, or connect to a gateway running on another machine."
            return
        }
        do {
            let running = try await runtime.start(LocalRuntimeConfiguration(
                executableURL: candidate.executableURL, arguments: candidate.arguments))
            let defaults = UserDefaults.standard
            let connectionID = defaults.string(forKey: "local.connection.id").flatMap(UUID.init(uuidString:)) ?? UUID()
            defaults.set(connectionID.uuidString, forKey: "local.connection.id")
            await model.connect(to: GatewayEndpoint(id: connectionID, name: "This Mac", baseURL: running.baseURL), token: running.token)
            if !model.isConnected { await runtime.stop() }
        } catch { model.banner = error.localizedDescription }
    }

    func stop() async { await model.disconnect(); await runtime.stop() }
}

@MainActor
final class HermesApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await MacCoordinator.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct HermesMacApp: App {
    @NSApplicationDelegateAdaptor(HermesApplicationDelegate.self) private var appDelegate
    private let coordinator = MacCoordinator.shared
    var body: some Scene {
        Window("Talaria", id: "main") {
            HermesRootView(model: coordinator.model, startLocal: { await coordinator.startLocal() })
                .frame(minWidth: 800, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { Task { await coordinator.model.newConversation() } }
                    .keyboardShortcut("n", modifiers: .command).disabled(!coordinator.model.isConnected)
            }
            CommandGroup(after: .appSettings) {
                Button("Gateway Connection…") { coordinator.model.showConnection = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
