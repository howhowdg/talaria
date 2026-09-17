import Foundation
import Darwin

public struct LocalRuntimeConfiguration: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var hermesHome: URL?
    public var profile: String
    public var workingDirectory: URL?
    public var startupTimeout: TimeInterval

    public init(
        executableURL: URL,
        arguments: [String] = [],
        hermesHome: URL? = nil,
        profile: String = "default",
        workingDirectory: URL? = nil,
        startupTimeout: TimeInterval = 90
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.hermesHome = hermesHome
        self.profile = profile
        self.workingDirectory = workingDirectory
        self.startupTimeout = startupTimeout
    }
}

public struct RunningRuntime: Sendable, Equatable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum LocalRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case alreadyRunning
    case invalidConfiguration(String)
    case launchFailed(String)
    case exited(Int32, String)
    case startupTimedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A local Hermes runtime is already starting or running."
        case .invalidConfiguration(let detail): detail
        case .launchFailed(let detail): "Could not start Hermes: \(detail)"
        case .exited(let code, let log): "Hermes exited before becoming ready (\(code)).\(log.isEmpty ? "" : "\n\(log)")"
        case .startupTimedOut: "Hermes did not announce a local port before the startup deadline."
        case .cancelled: "Local Hermes startup was cancelled."
        }
    }
}

/// Owns only children this manager launches. It never stops a separately running CLI or gateway.
/// The announced endpoint still needs the client's authenticated HTTP/WS readiness checks.
public actor LocalRuntimeManager {
    private var child: OwnedRuntimeProcess?
    private var previousLog = ""

    public init() {}

    public func start(_ config: LocalRuntimeConfiguration) async throws -> RunningRuntime {
        if let child, child.isRunningOrStarting { throw LocalRuntimeError.alreadyRunning }
        if let child { previousLog = child.logTail }
        let next = try OwnedRuntimeProcess(configuration: config)
        child = next
        do {
            let endpoint = try await next.start()
            guard child === next, next.isRunning, next.isRunningOrStarting else { throw LocalRuntimeError.cancelled }
            return endpoint
        } catch {
            await next.stop()
            if child === next {
                previousLog = next.logTail
                child = nil
            }
            throw error
        }
    }

    public func stop() async {
        guard let owned = child else { return }
        await owned.stop()
        if child === owned {
            previousLog = owned.logTail
            child = nil
        }
    }

    public func logTail() -> String { child?.logTail ?? previousLog }
}

/// Foundation process callbacks arrive on arbitrary threads. All mutable state and process
/// operations are protected by the lock; continuations are always resumed outside it.
private final class OwnedRuntimeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let token: String
    private let timeout: TimeInterval
    private var launched = false
    private var stopping = false
    private var exited = false
    private var outputTail = ""
    private var readyBuffer = ""
    private var startupResult: Result<RunningRuntime, LocalRuntimeError>?
    private var waiter: CheckedContinuation<RunningRuntime, any Error>?

    init(configuration: LocalRuntimeConfiguration) throws {
        guard configuration.executableURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw LocalRuntimeError.invalidConfiguration("Choose an executable Hermes CLI or Python interpreter.")
        }
        guard configuration.startupTimeout.isFinite, configuration.startupTimeout > 0 else {
            throw LocalRuntimeError.invalidConfiguration("The startup timeout must be greater than zero.")
        }
        guard !configuration.profile.contains("\0") else {
            throw LocalRuntimeError.invalidConfiguration("The profile name contains an invalid character.")
        }
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        timeout = configuration.startupTimeout
        process.executableURL = configuration.executableURL
        process.arguments = RuntimeLaunch.arguments(for: configuration)
        process.environment = RuntimeLaunch.environment(for: configuration, token: token)
        process.currentDirectoryURL = configuration.workingDirectory
            ?? configuration.hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
    }

    var isRunning: Bool { lock.withLock { launched && !exited && process.isRunning } }
    var isRunningOrStarting: Bool { lock.withLock { !exited && !stopping } }
    var logTail: String { lock.withLock { RuntimeLaunch.redact(outputTail, token: token) } }

    func start() async throws -> RunningRuntime {
        try Task.checkCancellation()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { self?.receive(data, stdout: true) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { self?.receive(data, stdout: false) }
        }
        process.terminationHandler = { [weak self] process in
            self?.didExit(code: process.terminationStatus)
        }
        do {
            try lock.withLock {
                guard !stopping else { throw LocalRuntimeError.cancelled }
                try process.run()
                launched = true
            }
        } catch let error as LocalRuntimeError {
            throw error
        } catch {
            lock.withLock { exited = true }
            throw LocalRuntimeError.launchFailed(RuntimeLaunch.redact(error.localizedDescription, token: token))
        }

        let deadline = Task { [timeout] in
            do {
                try await Task.sleep(for: .seconds(timeout))
                if finishStartup(.failure(.startupTimedOut)) { requestStop() }
            } catch { /* successful startup cancelled the timer */ }
        }
        defer { deadline.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<RunningRuntime, LocalRuntimeError>? = lock.withLock {
                    if let startupResult { return startupResult }
                    waiter = continuation
                    return nil
                }
                if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
            }
        } onCancel: {
            self.requestStop()
        }
    }

    private func receive(_ data: Data, stdout: Bool) {
        let text = String(decoding: data, as: UTF8.self)
        let port: Int? = lock.withLock {
            // Redact at the read boundary so credentials split across pipe chunks
            // cannot evade exact-token redaction.
            outputTail = String((outputTail + text).suffix(32_768))
            guard stdout, startupResult == nil, !stopping else { return nil }
            let combined = readyBuffer + text
            let found = RuntimeLaunch.readyPort(in: combined)
            readyBuffer = String(combined.suffix(512))
            return found
        }
        if let port, let url = URL(string: "http://127.0.0.1:\(port)") {
            finishStartup(.success(RunningRuntime(baseURL: url, token: token)))
        }
    }

    @discardableResult
    private func finishStartup(_ result: Result<RunningRuntime, LocalRuntimeError>) -> Bool {
        let completion: (Bool, CheckedContinuation<RunningRuntime, any Error>?) = lock.withLock {
            guard startupResult == nil else { return (false, nil) }
            if case .success = result, stopping { return (false, nil) }
            startupResult = result
            let saved = waiter
            waiter = nil
            return (true, saved)
        }
        completion.1?.resume(with: result.mapError { $0 as any Error })
        return completion.0
    }

    private func didExit(code: Int32) {
        lock.withLock { exited = true }
        finishStartup(.failure(.exited(code, logTail)))
    }

    private func requestStop() {
        lock.withLock {
            stopping = true
            if launched && !exited && process.isRunning { process.terminate() }
        }
        finishStartup(.failure(.cancelled))
    }

    func stop() async {
        // Cleanup must retain its grace period even when the startup task was cancelled.
        await Task.detached { [self] in
            requestStop()
            for _ in 0..<100 {
                if !isRunning { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            lock.withLock {
                if launched && !exited && process.isRunning {
                    // A still-owned unreaped Process cannot have had its PID reused.
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            for _ in 0..<100 {
                if !isRunning { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
        }.value
    }
}

enum RuntimeLaunch {
    static func arguments(for config: LocalRuntimeConfiguration) -> [String] {
        let name = config.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = name.isEmpty ? [] : ["--profile", name]
        return config.arguments + profile + ["serve", "--host", "127.0.0.1", "--port", "0"]
    }

    static func environment(
        for config: LocalRuntimeConfiguration,
        token: String,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = inherited
        if let home = config.hermesHome { env["HERMES_HOME"] = home.path }
        env["HERMES_DASHBOARD_SESSION_TOKEN"] = token
        env["HERMES_DESKTOP"] = "1"
        let parentPID = String(ProcessInfo.processInfo.processIdentifier)
        env["HERMES_PARENT_PID"] = parentPID
        // M1 uses the supported PID-only watchdog. Never inherit identity proof
        // for the process that launched us; a later exact-marker implementation
        // must generate marker and nonce together for this native process.
        env.removeValue(forKey: "HERMES_PARENT_START_MARKER")
        env.removeValue(forKey: "HERMES_PARENT_NONCE")
        env.removeValue(forKey: "HERMES_DESKTOP_READY_FILE")
        env["HERMES_SPAWN"] = "v1:-:serve:\(parentPID):-"
        env["PYTHONUTF8"] = env["PYTHONUTF8"] ?? "1"
        env["TERMINAL_CWD"] = (config.workingDirectory ?? config.hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser).path
        // Finder provides a minimal PATH; include common user/managed installs without
        // evaluating the user's shell initialization or reading credential files.
        var entries: [String] = []
        if let home = config.hermesHome { entries.append(home.appendingPathComponent("node/bin").path) }
        entries += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        entries += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        env["PATH"] = entries.filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    static func readyPort(in text: String) -> Int? {
        // Require a delimiter: a pipe read ending in port=43 may be followed by
        // 210\n. Accepting end-of-chunk would connect to the wrong port.
        let pattern = #"(?<!\w)HERMES_(?:BACKEND|DASHBOARD)_READY port=([0-9]+)(?=\s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let value = Int(text[range]), (1...65_535).contains(value) else { return nil }
        return value
    }

    static func redact(_ text: String, token: String) -> String {
        var result = text.replacingOccurrences(of: token, with: "<redacted>")
        for pattern in [
            #"(?i)([?&](?:token|ticket)=)[^\s&\"']+"#,
            #"(?i)(Authorization\s*:\s*Bearer\s+)[^\s]+"#,
            #"(?i)((?:HERMES_DASHBOARD_SESSION_TOKEN|X-Hermes-Session-Token)\s*[:=]\s*)[^\s]+"#
        ] {
            result = result.replacingOccurrences(of: pattern, with: "$1<redacted>", options: .regularExpression)
        }
        return result
    }
}
