import Foundation
import XCTest
@testable import HermesMacServices

final class LocalRuntimeManagerTests: XCTestCase {
    func testLaunchContractPinsProfileAndDoesNotInheritAnotherParentIdentity() {
        let config = LocalRuntimeConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-m", "hermes_cli.main"],
            hermesHome: URL(fileURLWithPath: "/tmp/Hermes Fixture"),
            profile: "research",
            workingDirectory: URL(fileURLWithPath: "/tmp/Project Space")
        )
        XCTAssertEqual(RuntimeLaunch.arguments(for: config), [
            "-m", "hermes_cli.main", "--profile", "research", "serve", "--host", "127.0.0.1", "--port", "0"
        ])
        let env = RuntimeLaunch.environment(for: config, token: "test-token", inherited: [
            "PATH": "/usr/bin:/bin", "HERMES_HOME": "/wrong",
            "HERMES_PARENT_START_MARKER": "old", "HERMES_PARENT_NONCE": "old",
            "HERMES_DESKTOP_READY_FILE": "/wrong/ready"
        ])
        XCTAssertEqual(env["HERMES_HOME"], "/tmp/Hermes Fixture")
        XCTAssertEqual(env["TERMINAL_CWD"], "/tmp/Project Space")
        XCTAssertEqual(env["HERMES_DESKTOP"], "1")
        XCTAssertEqual(env["HERMES_PARENT_PID"], String(ProcessInfo.processInfo.processIdentifier))
        XCTAssertNil(env["HERMES_PARENT_START_MARKER"])
        XCTAssertNil(env["HERMES_PARENT_NONCE"])
        XCTAssertNil(env["HERMES_DESKTOP_READY_FILE"])
        XCTAssertEqual(env["HERMES_DASHBOARD_SESSION_TOKEN"], "test-token")
        XCTAssertTrue(env["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    func testReadyParsingHandlesLegacyMergedOutputAndSplitPorts() {
        XCTAssertEqual(RuntimeLaunch.readyPort(in: "HERMES_BACKEND_READY port=54321\n"), 54321)
        XCTAssertEqual(RuntimeLaunch.readyPort(in: "server started]HERMES_DASHBOARD_READY port=32100\r\n"), 32100)
        XCTAssertNil(RuntimeLaunch.readyPort(in: "HERMES_BACKEND_READY port=43"))
        XCTAssertNil(RuntimeLaunch.readyPort(in: "HERMES_BACKEND_READY port=0\n"))
        XCTAssertNil(RuntimeLaunch.readyPort(in: "HERMES_BACKEND_READY port=65536\n"))
        XCTAssertNil(RuntimeLaunch.readyPort(in: "NOT_HERMES_BACKEND_READY port=32100\n"))
    }

    func testLogRedactionCoversTokensTicketsAndAuthorizationHeaders() {
        let log = RuntimeLaunch.redact(
            "secret=protected-value\nws://host/api/ws?ticket=ticket-value&profile=x\nAuthorization: Bearer bearer-value\nHERMES_DASHBOARD_SESSION_TOKEN=other-value",
            token: "protected-value"
        )
        for value in ["protected-value", "ticket-value", "bearer-value", "other-value"] {
            XCTAssertFalse(log.contains(value))
        }
        XCTAssertTrue(log.contains("profile=x"))
    }

    func testRealFixtureLaunchReportsEndpointPinsEnvironmentAndStopsOwnedProcess() async throws {
        let fixture = try RuntimeFixture(script: #"""
        printf '%s\n' "$@" > "$HERMES_HOME/arguments"
        printf '%s\n' "$HERMES_DESKTOP" "$HERMES_PARENT_PID" "$TERMINAL_CWD" > "$HERMES_HOME/environment"
        printf '%s' "$HERMES_DASHBOARD_SESSION_TOKEN" > "$HERMES_HOME/token"
        printf '%s' "$$" > "$HERMES_HOME/pid"
        printf 'HERMES_BACKEND_READY port=43'
        /bin/sleep 0.05
        printf '210\n'
        printf 'HERMES_DASHBOARD_SESSION_TOKEN=%s\n' "$HERMES_DASHBOARD_SESSION_TOKEN"
        exec /bin/sleep 30
        """#)
        defer { fixture.remove() }
        let manager = LocalRuntimeManager()
        let running = try await manager.start(fixture.configuration)
        XCTAssertEqual(running.baseURL.absoluteString, "http://127.0.0.1:43210")
        XCTAssertTrue(running.token.count >= 64)
        XCTAssertTrue(try fixture.read("token") == running.token)
        XCTAssertEqual(try fixture.read("arguments").split(separator: "\n").map(String.init), [
            "--profile", "fixture", "serve", "--host", "127.0.0.1", "--port", "0"
        ])
        XCTAssertTrue(try fixture.read("environment").contains(fixture.directory.path))
        await manager.stop()
        let log = await manager.logTail()
        XCTAssertFalse(log.contains(running.token))
        let pid = try XCTUnwrap(Int32(fixture.read("pid")))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testStartupTimeoutTerminatesOnlyItsFixtureAndAllowsRestart() async throws {
        let fixture = try RuntimeFixture(script: #"""
        printf '%s' "$$" > "$HERMES_HOME/pid"
        exec /bin/sleep 30
        """#, timeout: 0.15)
        defer { fixture.remove() }
        let manager = LocalRuntimeManager()
        do {
            _ = try await manager.start(fixture.configuration)
            XCTFail("Expected the startup deadline")
        } catch {
            XCTAssertEqual(error as? LocalRuntimeError, .startupTimedOut)
        }
        let pid = try XCTUnwrap(Int32(fixture.read("pid")))
        XCTAssertEqual(kill(pid, 0), -1)
        await manager.stop()
        let next = try RuntimeFixture(script: "printf 'HERMES_BACKEND_READY port=43211\\n'\nexec /bin/sleep 30")
        defer { next.remove() }
        let running = try await manager.start(next.configuration)
        XCTAssertEqual(running.baseURL.port, 43211)
        await manager.stop()
    }

    func testCancellationTearsDownAStartingChild() async throws {
        let fixture = try RuntimeFixture(script: #"""
        printf '%s' "$$" > "$HERMES_HOME/pid"
        exec /bin/sleep 30
        """#)
        defer { fixture.remove() }
        let manager = LocalRuntimeManager()
        let starting = Task { try await manager.start(fixture.configuration) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pid").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        starting.cancel()
        do {
            _ = try await starting.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || error as? LocalRuntimeError == .cancelled)
        }
        let pid = try XCTUnwrap(Int32(fixture.read("pid")))
        XCTAssertEqual(kill(pid, 0), -1)
        await manager.stop()
    }

    func testEarlyExitReportsFailureInsteadOfWaitingForTimeout() async throws {
        let fixture = try RuntimeFixture(script: "exit 7")
        defer { fixture.remove() }
        let manager = LocalRuntimeManager()
        do {
            _ = try await manager.start(fixture.configuration)
            XCTFail("Expected child exit")
        } catch let error as LocalRuntimeError {
            guard case .exited(let code, _) = error else { return XCTFail("Wrong startup error") }
            XCTAssertEqual(code, 7)
        }
    }

    func testDiscoveryOnlyListsExecutableMetadata() throws {
        let fixture = try RuntimeFixture(script: "exit 99")
        defer { fixture.remove() }
        let candidates = RuntimeDiscovery.candidates(
            environment: ["PATH": "", "HERMES_HOME": fixture.directory.path,
                          "HERMES_DESKTOP_HERMES": "/bin/sh"],
            homeDirectory: fixture.directory
        )
        XCTAssertEqual(candidates.first?.executableURL.path, "/bin/sh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pid").path))
    }
}

private struct RuntimeFixture: Sendable {
    let directory: URL
    let configuration: LocalRuntimeConfiguration

    init(script: String, timeout: TimeInterval = 3) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hermes Runtime \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("backend.sh")
        try Data(script.utf8).write(to: scriptURL)
        configuration = LocalRuntimeConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [scriptURL.path], hermesHome: directory, profile: "fixture",
            workingDirectory: directory, startupTimeout: timeout
        )
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
