import XCTest
@testable import HermesMacServices

final class RemoteHermesManagerTests: XCTestCase {
    func testCancellationMarkerIsRemovedAfterFinalCleanup() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let owner = String(repeating: "a", count: 32)
        let nonce = String(repeating: "b", count: 16)
        let root = home.appendingPathComponent(".hermes/desktop-ssh/\(owner)")
        for phase in ["fence", "final"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", RemoteHermesManager.stopScript, owner, nonce, "0", phase]
            process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { _, new in new }
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(FileManager.default.fileExists(atPath: root.path), phase == "fence")
        }
    }

    private actor DelayedSSH {
        private var started: CheckedContinuation<Void, Never>?
        private var releaseStart: CheckedContinuation<Void, Never>?
        private var ready = false
        private var released = false
        private(set) var cleanupCount = 0
        private(set) var cleanupPhases: [String] = []

        func waitForStart() async {
            if ready { return }
            await withCheckedContinuation { started = $0 }
        }

        func release() { released = true; releaseStart?.resume(); releaseStart = nil }

        func run(_ config: SSHConfiguration, _ script: String, _ arguments: [String],
                 _ input: String?, _ timeout: TimeInterval) async throws -> String {
            if input == nil {
                cleanupCount += 1
                XCTAssertEqual(arguments.dropLast().last, "0")
                cleanupPhases.append(arguments.last ?? "")
                return ""
            }
            ready = true
            started?.resume()
            started = nil
            try await withTaskCancellationHandler {
                await withCheckedContinuation {
                    if released { $0.resume() }
                    else { releaseStart = $0 }
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.release() }
            }
            return "{\"port\":54321,\"pid\":123,\"nonce\":\"\(arguments[1])\"}\n"
        }
    }

    func testStopDuringStartupIsPromptAndFenced() async throws {
        let ssh = DelayedSSH()
        let manager = RemoteHermesManager(runner: { try await ssh.run($0, $1, $2, $3, $4) })
        let config = SSHConfiguration(host: "mini.tailnet.ts.net", gatewayPort: 9119)
        let first = Task { try await manager.start(config) }
        await ssh.waitForStart()
        do {
            _ = try await manager.start(config)
            XCTFail("Concurrent startup should be rejected")
        } catch RemoteHermesError.alreadyRunning { }
        let began = Date()
        await manager.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        do {
            _ = try await first.value
            XCTFail("Stopped startup should not return a live port")
        } catch is CancellationError { }
        let cleanupCount = await ssh.cleanupCount
        XCTAssertEqual(cleanupCount, 2)
        let phases = await ssh.cleanupPhases
        XCTAssertEqual(phases, ["fence", "final"])
    }

    func testCancellationDuringStartupCleansUp() async {
        let ssh = DelayedSSH()
        let manager = RemoteHermesManager(runner: { try await ssh.run($0, $1, $2, $3, $4) })
        let config = SSHConfiguration(host: "mini.tailnet.ts.net", gatewayPort: 9119)
        let starting = Task { try await manager.start(config) }
        await ssh.waitForStart()
        starting.cancel()
        do {
            _ = try await starting.value
            XCTFail("Cancelled startup should not return a live port")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        let cleanupCount = await ssh.cleanupCount
        XCTAssertEqual(cleanupCount, 2)
        let phases = await ssh.cleanupPhases
        XCTAssertEqual(phases, ["fence", "final"])
    }

    func testSSHUsesLocalKeysAndKnownHostsWithoutPuttingTokenInArguments() async {
        let config = SSHConfiguration(host: "mini.tailnet.ts.net", user: "tom", gatewayPort: 9119)
        let args = RemoteHermesManager.sshArguments(config, script: "print('ready')", arguments: ["nonce", "default"])
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ClearAllForwardings=yes"))
        XCTAssertTrue(args.contains("tom@mini.tailnet.ts.net"))
        XCTAssertFalse(args.joined(separator: " ").contains("session-secret"))

        do {
            _ = try await RemoteHermesManager().start(config, profile: "-invalid")
            XCTFail("A profile must not become a command option")
        } catch RemoteHermesError.launchFailed { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
