import Foundation
import Darwin

public struct SSHConfiguration: Sendable {
    public var host: String
    public var user: String?
    public var sshPort: Int
    public var identityFile: URL?
    public var gatewayPort: Int
    public var gatewayPath: String
    public var startupTimeout: TimeInterval

    public init(host: String, user: String? = nil, sshPort: Int = 22,
                identityFile: URL? = nil, gatewayPort: Int, gatewayPath: String = "",
                startupTimeout: TimeInterval = 10) {
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.identityFile = identityFile
        self.gatewayPort = gatewayPort
        self.gatewayPath = gatewayPath
        self.startupTimeout = startupTimeout
    }
}

public struct RunningSSHTunnel: Sendable, Equatable {
    public let baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }
}

public enum SSHTunnelError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case alreadyRunning
    case launchFailed
    case authenticationFailed
    case hostKeyFailed
    case exited(Int32)
    case startupTimedOut
    case cancelled
    case bindCollision

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): detail
        case .alreadyRunning: "An SSH tunnel is already starting or running."
        case .launchFailed: "Could not start SSH."
        case .authenticationFailed: "SSH authentication failed. Check the selected key and SSH user."
        case .hostKeyFailed: "SSH could not verify this host. Add its key to known_hosts using your trusted SSH workflow."
        case .exited: "The SSH tunnel closed."
        case .startupTimedOut: "SSH did not open a local port before the startup deadline."
        case .cancelled: "SSH tunnel startup was cancelled."
        case .bindCollision: "The local SSH port was taken."
        }
    }
}

/// Owns only its SSH child. The caller still checks the forwarded gateway over HTTP.
public actor SSHTunnelManager {
    private var child: OwnedSSHTunnel?
    private var currentURL: URL?

    public init() {}

    public func start(_ config: SSHConfiguration) async throws -> RunningSSHTunnel {
        try SSHLaunch.validate(config)
        if let child, child.isRunningOrStarting { throw SSHTunnelError.alreadyRunning }
        self.child = nil
        currentURL = nil
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let port = try SSHLaunch.availablePort()
            try await SSHLaunch.preflight(config, localPort: port)
            try Task.checkCancellation()
            let next = OwnedSSHTunnel(config: config, port: port)
            child = next
            do {
                let running = try await next.start()
                guard child === next, next.isRunning else { throw SSHTunnelError.cancelled }
                currentURL = running.baseURL
                return running
            } catch {
                await next.stop()
                if child === next { child = nil; currentURL = nil }
                if error as? SSHTunnelError == .bindCollision && attempt < 2 { continue }
                throw error
            }
        }
        throw SSHTunnelError.bindCollision
    }

    public func stop() async {
        guard let owned = child else { return }
        await owned.stop()
        if child === owned { child = nil; currentURL = nil }
    }

    public func runningURL() -> URL? {
        guard child?.isRunning == true else { return nil }
        return currentURL
    }

    public func waitForExit() async {
        guard let child else { return }
        await child.waitForExit()
    }
}

enum SSHLaunch {
    static func validate(_ config: SSHConfiguration) throws {
        // Process arguments prevent shell injection; these checks prevent SSH option parsing
        // and malformed destinations from changing which machine receives the connection.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !config.host.isEmpty, !config.host.hasPrefix("-"),
              config.host.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SSHTunnelError.invalidConfiguration("Enter an SSH hostname or IPv4 address.")
        }
        if let user = config.user {
            guard !user.isEmpty, !user.hasPrefix("-"),
                  user.unicodeScalars.allSatisfy(allowed.contains) else {
                throw SSHTunnelError.invalidConfiguration("Enter a valid SSH user.")
            }
        }
        guard (1...65_535).contains(config.sshPort), (1...65_535).contains(config.gatewayPort) else {
            throw SSHTunnelError.invalidConfiguration("SSH and gateway ports must be between 1 and 65535.")
        }
        guard config.startupTimeout.isFinite, config.startupTimeout > 0 else {
            throw SSHTunnelError.invalidConfiguration("The SSH startup timeout must be greater than zero.")
        }
        if let identity = config.identityFile {
            guard identity.isFileURL, FileManager.default.isReadableFile(atPath: identity.path) else {
                throw SSHTunnelError.invalidConfiguration("Choose a readable SSH private key file.")
            }
        }
        guard config.gatewayPath.isEmpty ||
                (config.gatewayPath.hasPrefix("/") && !config.gatewayPath.hasPrefix("//") &&
                 !config.gatewayPath.contains("?") && !config.gatewayPath.contains("#") &&
                 !config.gatewayPath.contains("\0")) else {
            throw SSHTunnelError.invalidConfiguration("Gateway path must start with a single slash.")
        }
    }

    static func arguments(for config: SSHConfiguration, localPort: Int) -> [String] {
        var args = ["-v", "-N", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ExitOnForwardFailure=yes", "-o", "PermitLocalCommand=no",
                    "-o", "ForwardAgent=no", "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none"]
        if config.sshPort != 22 { args += ["-p", String(config.sshPort)] }
        if let identity = config.identityFile { args += ["-i", identity.path] }
        args += ["-L", "127.0.0.1:\(localPort):127.0.0.1:\(config.gatewayPort)"]
        args += [config.user.map { "\($0)@\(config.host)" } ?? config.host]
        return args
    }

    static func readyPort(in text: String, matching expectedPort: Int? = nil) -> Int? {
        let pattern = #"Local forwarding listening on 127\.0\.0\.1 port ([0-9]+)\.\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text),
               let port = Int(text[range]), (1...65_535).contains(port),
               expectedPort == nil || expectedPort == port { return port }
        }
        return nil
    }

    static func preflight(_ config: SSHConfiguration, localPort: Int) async throws {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-G"] + arguments(for: config, localPort: localPort)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw SSHTunnelError.launchFailed }
            // ssh -G reads local config only, but Match exec may run a user command.
            // Bound that work and drain stdout so a large config cannot block the child.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
            var data = Data()
            var oversized = false
            while let chunk = try? output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                if data.count + chunk.count <= 131_072 { data.append(chunk) }
                else { oversized = true }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, !oversized,
                  let text = String(data: data, encoding: .utf8),
                  resolvedForwardingsAreSafe(text, config: config, localPort: localPort) else {
                throw SSHTunnelError.invalidConfiguration("SSH configuration adds forwards or could not be checked.")
            }
        }.value
    }

    static func resolvedForwardingsAreSafe(_ output: String, config: SSHConfiguration, localPort: Int) -> Bool {
        let forwards = output.split(separator: "\n").map(String.init).filter {
            $0.hasPrefix("localforward ") || $0.hasPrefix("remoteforward ") ||
            $0.hasPrefix("dynamicforward ")
        }
        return forwards == ["localforward [127.0.0.1]:\(localPort) [127.0.0.1]:\(config.gatewayPort)"]
    }

    static func availablePort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHTunnelError.launchFailed }
        defer { Darwin.close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                                  sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: in_addr_t(0x7f000001).bigEndian),
                                  sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw SSHTunnelError.launchFailed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard found == 0 else { throw SSHTunnelError.launchFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private final class OwnedSSHTunnel: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let errors = Pipe()
    private let port: Int
    private let path: String
    private let timeout: TimeInterval
    private var launched = false
    private var stopped = false
    private var exited = false
    private var stderrBuffer = ""
    private var sawBindCollision = false
    private var sawAuthFailure = false
    private var sawHostKeyFailure = false
    private var startupResult: Result<RunningSSHTunnel, SSHTunnelError>?
    private var startupWaiter: CheckedContinuation<RunningSSHTunnel, any Error>?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    init(config: SSHConfiguration, port: Int) {
        self.port = port
        path = config.gatewayPath
        timeout = config.startupTimeout
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHLaunch.arguments(for: config, localPort: port)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
    }

    var isRunning: Bool { lock.withLock { launched && !exited && process.isRunning } }
    var isRunningOrStarting: Bool { lock.withLock { !stopped && !exited } }

    func start() async throws -> RunningSSHTunnel {
        try Task.checkCancellation()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] process in
            self?.didExit(code: process.terminationStatus)
        }
        do {
            try lock.withLock {
                guard !stopped else { throw SSHTunnelError.cancelled }
                try process.run()
                launched = true
            }
        } catch let error as SSHTunnelError {
            throw error
        } catch {
            lock.withLock { exited = true }
            throw SSHTunnelError.launchFailed
        }

        let deadline = Task { [timeout] in
            do {
                try await Task.sleep(for: .seconds(timeout))
                if finishStartup(.failure(.startupTimedOut)) { requestStop() }
            } catch { }
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<RunningSSHTunnel, SSHTunnelError>? = lock.withLock {
                    if let startupResult { return startupResult }
                    startupWaiter = continuation
                    return nil
                }
                if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
            }
        } onCancel: { self.requestStop() }
    }

    private func receive(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let ready: Bool = lock.withLock {
            stderrBuffer = String((stderrBuffer + text).suffix(4096))
            sawBindCollision = sawBindCollision || stderrBuffer.contains("Address already in use")
            sawAuthFailure = sawAuthFailure || stderrBuffer.contains("Permission denied (")
            sawHostKeyFailure = sawHostKeyFailure || stderrBuffer.contains("Host key verification failed") ||
                stderrBuffer.contains("No ") && stderrBuffer.contains(" host key is known")
            return !stopped && startupResult == nil && SSHLaunch.readyPort(in: stderrBuffer, matching: port) != nil
        }
        if ready, let url = URL(string: "http://127.0.0.1:\(port)\(path)") {
            finishStartup(.success(RunningSSHTunnel(baseURL: url)))
        }
    }

    @discardableResult
    private func finishStartup(_ result: Result<RunningSSHTunnel, SSHTunnelError>) -> Bool {
        let completion: (Bool, CheckedContinuation<RunningSSHTunnel, any Error>?) = lock.withLock {
            guard startupResult == nil else { return (false, nil) }
            if case .success = result, stopped { return (false, nil) }
            startupResult = result
            let saved = startupWaiter
            startupWaiter = nil
            return (true, saved)
        }
        completion.1?.resume(with: result.mapError { $0 as any Error })
        return completion.0
    }

    private func didExit(code: Int32) {
        let completion: (SSHTunnelError, [CheckedContinuation<Void, Never>]) = lock.withLock {
            exited = true
            let error: SSHTunnelError = sawBindCollision ? .bindCollision :
                sawHostKeyFailure ? .hostKeyFailed : sawAuthFailure ? .authenticationFailed : .exited(code)
            let waiters = exitWaiters
            exitWaiters = []
            return (error, waiters)
        }
        finishStartup(.failure(completion.0))
        completion.1.forEach { $0.resume() }
    }

    private func requestStop() {
        lock.withLock {
            stopped = true
            if launched && !exited && process.isRunning { process.terminate() }
        }
        finishStartup(.failure(.cancelled))
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if exited { return true }
                exitWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    func stop() async {
        await Task.detached { [self] in
            requestStop()
            for _ in 0..<100 {
                if !isRunning { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            lock.withLock {
                if launched && !exited && process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            for _ in 0..<100 {
                if !isRunning { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            errors.fileHandleForReading.readabilityHandler = nil
        }.value
    }
}
