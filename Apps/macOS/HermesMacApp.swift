import SwiftUI
import AppKit
import HermesCore
import HermesUI
import HermesTransport
import HermesMacServices
#if DEBUG
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
#endif

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
                .dynamicTypeSize(.medium)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { Task { await coordinator.model.newConversation() } }
                    .keyboardShortcut("n", modifiers: .command).disabled(!coordinator.model.isConnected)
            }
            CommandGroup(after: .appSettings) {
                Button("Gateway Connection…") { coordinator.model.showConnection = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            #if DEBUG
            CommandGroup(after: .windowSize) {
                Button("Design Reference Size (1180 × 760)") {
                    NSApp.keyWindow?.setContentSize(NSSize(width: 1180, height: 760))
                }
                if #available(macOS 14.4, *) {
                    Button("Export 2× Design Snapshot…", action: exportDesignSnapshot)
                } else {
                    Button("Export 2× View Render…", action: exportDesignSnapshot)
                }
            }
            #endif
        }
    }

    #if DEBUG
    /// Capture only this process's window through the compositor. Capture before
    /// presenting the save panel, which otherwise changes the window's appearance.
    @MainActor private func exportDesignSnapshot() {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
              let view = window.contentView else { return }
        Task { @MainActor in
            do {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                if #available(macOS 14.4, *) {
                    let snapshot = try await captureDesignWindow(window)
                    try saveDesignSnapshot(snapshot.image, scale: snapshot.scale, isCapture: true)
                } else {
                    try saveDesignSnapshot(renderLegacyDesignView(view), scale: 2, isCapture: false)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @available(macOS 14.4, *)
    @MainActor private func captureDesignWindow(_ window: NSWindow) async throws -> (image: CGImage, scale: CGFloat) {
        // This API deliberately excludes other applications and does not request
        // Screen Recording permission. Never fall back to all-process content.
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw DesignSnapshotError.windowUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let sourceScale = min(CGFloat(filter.pointPixelScale), window.backingScaleFactor)
        let size = filter.contentRect.size
        guard sourceScale.isFinite, sourceScale > 0,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw DesignSnapshotError.invalidDimensions
        }
        // A larger requested surface is not proof of native 2× detail. Use only
        // available backing pixels, and label lower-resolution captures honestly.
        let scale = min(2, sourceScale)
        let config = SCStreamConfiguration()
        config.width = Int((size.width * scale).rounded())
        config.height = Int((size.height * scale).rounded())
        config.captureResolution = .best
        config.scalesToFit = false
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        config.includeChildWindows = false
        config.showsCursor = false
        config.shouldBeOpaque = false
        // Keep the display color space and its image profile; do not retag its
        // pixels as device RGB or flatten translucent edges onto white.
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard image.width == config.width, image.height == config.height else {
            throw DesignSnapshotError.invalidDimensions
        }
        return (image, scale)
    }

    @MainActor private func saveDesignSnapshot(_ image: CGImage, scale: CGFloat, isCapture: Bool) throws {
        let panel = NSSavePanel()
        let scaleLabel = String(format: "%g", Double(scale))
        panel.nameFieldStringValue = isCapture ? "talaria-mac-native-\(scaleLabel)x.png" : "talaria-mac-view-render-2x.png"
        panel.allowedContentTypes = [.png]
        if !isCapture {
            panel.message = "View render only: macOS 14.4 or later is required for an app-only native capture. This render may omit composited materials."
        } else if scale < 2 {
            panel.message = "Native 2× is unavailable on this window's display. Saving the actual \(scaleLabel)× capture (\(image.width) × \(image.height) pixels) without upscaling."
        } else {
            panel.message = "Native window capture: \(image.width) × \(image.height) pixels, without the outer window shadow."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DesignSnapshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DesignSnapshotError.encodingFailed }
    }

    @MainActor private func renderLegacyDesignView(_ view: NSView) throws -> CGImage {
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw DesignSnapshotError.encodingFailed }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw DesignSnapshotError.encodingFailed }
        return image
    }
    #endif
}

#if DEBUG
private enum DesignSnapshotError: LocalizedError {
    case windowUnavailable, invalidDimensions, encodingFailed

    var errorDescription: String? {
        switch self {
        case .windowUnavailable: "The Talaria window is not available for an app-only capture. Keep it visible and try again."
        case .invalidDimensions: "The window's native capture dimensions could not be verified. No resized snapshot was saved."
        case .encodingFailed: "The design snapshot could not be written as a PNG."
        }
    }
}
#endif
