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

    #if DEBUG
    /// A manually invoked preview connects only to an expiring, loopback fixture.
    /// It never changes saved connection credentials or production classifications.
    func openHierarchyFixture() async {
        do {
            let fixture = try HierarchyDesignFixture.load()
            let fixtureID = UUID(uuidString: "7DBFDE9E-503B-4D63-8C88-6AC61A78E0A4")!
            await model.connect(to: GatewayEndpoint(id: fixtureID, name: "Hermes", baseURL: fixture.url),
                                token: fixture.token, remember: false)
            guard model.isConnected, let owner = model.currentHierarchyOwner,
                  model.sessions.contains(where: { $0.id.rawValue == "design-home" }) else { return }
            model.classificationStore.update(for: owner) { $0 = HierarchyClassification() }
            _ = model.createWorkspace(name: "Plan a trip", purpose: "Lisbon, Oct 9–12, under €900.",
                swatch: "#3B7DDD", sessionID: .init(rawValue: "design-lisbon-weekend"))
            _ = model.createWorkspace(name: "Build Talaria", purpose: "SwiftUI client for Hermes. Running tests.",
                swatch: "#858985", sessionID: .init(rawValue: "design-downloads-review"))
            if let id = model.createWorkspace(name: "Move apartment", purpose: "The move is complete.",
                swatch: "#858985", sessionID: .init(rawValue: "design-sunday-notes")) { model.archiveWorkspace(id) }
            await model.openSession(.init(rawValue: "design-downloads-review"))
            model.recordLineage(child: .init(rawValue: "design-lisbon-weekend"),
                parent: .init(rawValue: "design-home"), kind: .branch)
            await model.refreshMobileActivity()
            await model.navigate(to: .home)
            model.showConnection = false
        } catch { model.banner = "The synthetic hierarchy fixture is unavailable or expired. Start the design fixture and try again." }
    }

    func previewMissingHome() async {
        guard model.endpoint?.id.uuidString == "7DBFDE9E-503B-4D63-8C88-6AC61A78E0A4",
              let owner = model.currentHierarchyOwner else { return }
        await model.chooseHome(.init(rawValue: "design-home"))
        model.classificationStore.update(for: owner) { $0.homeSessionID = .init(rawValue: "design-missing-home") }
        await model.navigate(to: .home)
    }
    #endif
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
                Button("New Conversation") { NotificationCenter.default.post(name: .talariaNewConversation, object: nil) }
                    .keyboardShortcut("n", modifiers: .command).disabled(!coordinator.model.isConnected)
            }
            CommandGroup(after: .appSettings) {
                Button("Gateway Connection…") { coordinator.model.showConnection = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            #if DEBUG
            CommandGroup(after: .windowSize) {
                Button("Open Hierarchy Design Fixture") { Task { await coordinator.openHierarchyFixture() } }
                Button("Preview Home Unavailable") { Task { await coordinator.previewMissingHome() } }
                Button("Preview Dark Appearance") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                Button("Use System Appearance") { NSApp.appearance = nil }
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
private struct HierarchyDesignFixture {
    let url: URL
    let token: String
    static func load() throws -> Self {
        let fd = Darwin.open("/tmp/talaria-hierarchy-design-fixture.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DesignSnapshotError.windowUnavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 16_384 else { throw DesignSnapshotError.windowUnavailable }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        guard data.count <= 16_384,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["fixture_kind"] as? String == "synthetic-mobile-design-only",
              json["profile"] as? String == "default",
              let expiry = json["expires_at"] as? Double, expiry.isFinite,
              expiry > Date().timeIntervalSince1970, expiry - Date().timeIntervalSince1970 <= 1800,
              let raw = json["base_url"] as? String, let url = URL(string: raw),
              url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let token = json["token"] as? String, !token.isEmpty, token.utf8.count <= 4096,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw DesignSnapshotError.windowUnavailable }
        return Self(url: url, token: token)
    }
}

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
