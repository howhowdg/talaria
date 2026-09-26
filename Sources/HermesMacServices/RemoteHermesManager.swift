import Foundation
import Security
import Darwin

public enum RemoteHermesError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case launchFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A remote Hermes server is already running."
        case .launchFailed(let detail): "Could not start remote Hermes: \(detail)"
        case .invalidResponse: "Remote Hermes did not announce a valid port."
        }
    }
}

/// Starts only a Talaria-owned, loopback-bound Hermes serve. SSH keys and known_hosts
/// come from the local OpenSSH configuration; the gateway token travels on stdin.
public actor RemoteHermesManager {
    typealias Runner = @Sendable (SSHConfiguration, String, [String], String?, TimeInterval) async throws -> String

    private struct Pending {
        let config: SSHConfiguration
        let owner: String
        let nonce: String
        let task: Task<String, Error>
        var stopRequested = false
    }

    private let runner: Runner
    private var pending: Pending?
    // ponytail: force-quit can leave a private remote process; add stale-owner recovery if that occurs in practice.
    private var owned: (config: SSHConfiguration, pid: Int, owner: String, nonce: String)?

    public init() {
        runner = { config, script, arguments, input, timeout in
            try await Self.run(config, script: script, arguments: arguments, input: input, timeout: timeout)
        }
    }

    init(runner: @escaping Runner) { self.runner = runner }

    public func start(_ config: SSHConfiguration, profile: String = "default") async throws -> Int {
        guard owned == nil, pending == nil else { throw RemoteHermesError.alreadyRunning }
        try SSHLaunch.validate(config)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !profile.isEmpty, !profile.hasPrefix("-"),
              profile.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RemoteHermesError.launchFailed("Invalid Hermes profile.")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemoteHermesError.launchFailed("Could not create a session token.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let owner = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let nonce = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        let task = Task { try await runner(config, Self.startScript, [owner, nonce, profile], token, 65) }
        pending = Pending(config: config, owner: owner, nonce: nonce, task: task)
        do {
            let output = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.stopPending(owner: owner, nonce: nonce) }
            }
            guard let line = output.split(separator: "\n").last,
                  let data = String(line).data(using: .utf8),
                  let result = try? JSONDecoder().decode(StartResult.self, from: data),
                  result.nonce == nonce, result.pid > 0, (1...65_535).contains(result.port) else {
                throw RemoteHermesError.invalidResponse
            }
            guard pending?.nonce == nonce, pending?.stopRequested == false, !Task.isCancelled else {
                throw CancellationError()
            }
            pending = nil
            owned = (config, result.pid, owner, nonce)
            return result.port
        } catch {
            if pending?.nonce == nonce {
                pending = nil
                await cleanup(config, owner: owner, nonce: nonce)
            }
            throw error
        }
    }

    public func stop() async {
        let starting = pending
        if let current = owned {
            owned = nil
            await cleanup(current.config, owner: current.owner, nonce: current.nonce, pid: current.pid)
        }
        if let starting {
            await stopPending(owner: starting.owner, nonce: starting.nonce)
        }
    }

    private func stopPending(owner: String, nonce: String) async {
        guard let starting = pending, starting.owner == owner, starting.nonce == nonce,
              !starting.stopRequested else { return }
        pending?.stopRequested = true
        // Fence the remote nonce before interrupting SSH, so a late spawn cannot survive us.
        await cleanup(starting.config, owner: owner, nonce: nonce, timeout: 5, final: false)
        starting.task.cancel()
        _ = await starting.task.result
        if pending?.nonce == nonce {
            pending = nil
            await cleanup(starting.config, owner: owner, nonce: nonce, timeout: 5)
        }
    }

    private func cleanup(_ config: SSHConfiguration, owner: String, nonce: String,
                         pid: Int = 0, timeout: TimeInterval = 15, final: Bool = true) async {
        _ = try? await runner(config, Self.stopScript,
                              [owner, nonce, String(pid), final ? "final" : "fence"], nil, timeout)
    }

    private struct StartResult: Decodable {
        let port: Int
        let pid: Int
        let nonce: String
    }

    static func sshArguments(_ config: SSHConfiguration, script: String, arguments: [String]) -> [String] {
        var result = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                      "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
                      "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=10",
                      "-o", "ControlMaster=no", "-o", "ControlPath=none"]
        if config.sshPort != 22 { result += ["-p", String(config.sshPort)] }
        if let identity = config.identityFile { result += ["-i", identity.path] }
        result.append(config.user.map { "\($0)@\(config.host)" } ?? config.host)
        result.append("python3 -c \(quote(script)) \(arguments.map(quote).joined(separator: " "))")
        return result
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ config: SSHConfiguration, script: String, arguments: [String],
                            input: String? = nil, timeout: TimeInterval) async throws -> String {
        let process = Process()
        let worker = Task.detached {
            try Task.checkCancellation()
            let output = Pipe()
            let stdin = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArguments(config, script: script, arguments: arguments)
            process.standardOutput = output
            process.standardError = output
            process.standardInput = stdin
            do { try process.run() } catch { throw RemoteHermesError.launchFailed("SSH could not start.") }
            if Task.isCancelled { process.terminate() }
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try? stdin.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            var data = Data()
            while let chunk = try? output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 65_536 {
                    if process.isRunning { process.terminate() }
                    break
                }
            }
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0, data.count <= 65_536 else {
                throw RemoteHermesError.launchFailed(String(text.suffix(500)))
            }
            return text
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            if process.isRunning { process.terminate() }
        }
    }

    private static let startScript = #"""
import json, os, pathlib, re, shutil, signal, stat, subprocess, sys, time
owner, nonce, profile = sys.argv[1:4]
base = pathlib.Path.home() / '.hermes' / 'desktop-ssh'
base.mkdir(mode=0o700, parents=True, exist_ok=True)
root = base / owner
root.mkdir(mode=0o700, parents=True, exist_ok=True)
info = root.stat()
if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
    raise SystemExit('Unsafe remote session directory')
hermes = next((str(p) for p in (pathlib.Path.home()/'.hermes/hermes-agent/venv/bin/hermes', pathlib.Path.home()/'.local/bin/hermes') if p.is_file() and os.access(p, os.X_OK)), shutil.which('hermes'))
if not hermes:
    raise SystemExit('Hermes is not installed on the remote Mac')
token_path, log_path, state_path = (root / (nonce + suffix) for suffix in ('.token', '.log', '.json'))
cancel_path = root / (nonce + '.cancel')
token = sys.stdin.buffer.read(256)
if not 32 <= len(token) <= 128:
    raise SystemExit('Invalid session token')
fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
try:
    os.write(fd, token)
finally:
    os.close(fd)
process = None
try:
    if cancel_path.exists():
        raise RuntimeError('Remote connection was cancelled')
    with open(log_path, 'x', encoding='utf-8') as log:
        env = dict(os.environ, HERMES_DESKTOP='1')
        args = [hermes] + (['--profile', profile] if profile != 'default' else []) + ['serve', '--isolated', '--host', '127.0.0.1', '--port', '0', '--ssh-session-token-file', str(token_path), '--ssh-owner-nonce', nonce]
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True, env=env)
    fd = os.open(state_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        os.write(fd, json.dumps({'pid': process.pid, 'nonce': nonce}).encode())
    finally:
        os.close(fd)
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        if cancel_path.exists():
            raise RuntimeError('Remote connection was cancelled')
        if process.poll() is not None:
            raise RuntimeError('Remote Hermes exited before it became ready')
        match = re.search(r'^HERMES_(?:BACKEND|DASHBOARD)_READY port=([0-9]+)\s*$', log_path.read_text(errors='replace'), re.M)
        if match:
            port = int(match.group(1))
            if not 1 <= port <= 65535:
                raise RuntimeError('Invalid remote gateway port')
            print(json.dumps({'port': port, 'pid': process.pid, 'nonce': nonce}), flush=True)
            break
        time.sleep(0.25)
    else:
        raise RuntimeError('Remote Hermes did not become ready')
except BaseException:
    if process and process.poll() is None:
        process.terminate()
    for path in (token_path, log_path, state_path):
        path.unlink(missing_ok=True)
    raise
"""#

    static let stopScript = #"""
import json, os, pathlib, signal, subprocess, sys
owner, nonce, expected_pid, phase = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
root = pathlib.Path.home() / '.hermes' / 'desktop-ssh' / owner
root.mkdir(mode=0o700, parents=True, exist_ok=True)
info = root.stat()
if not root.is_dir() or info.st_uid != os.getuid() or info.st_mode & 0o077:
    raise SystemExit('Unsafe remote session directory')
cancel_path = root / (nonce + '.cancel')
try:
    fd = os.open(cancel_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    os.close(fd)
except FileExistsError:
    pass
state = root / (nonce + '.json')
def finish():
    if phase == 'final':
        cancel_path.unlink(missing_ok=True)
        try:
            root.rmdir()
        except OSError:
            pass
try:
    record = json.loads(state.read_text())
except FileNotFoundError:
    finish()
    raise SystemExit(0)
except (OSError, ValueError):
    raise SystemExit(0)
if record.get('nonce') != nonce or (expected_pid and record.get('pid') != expected_pid):
    raise SystemExit(0)
expected_pid = record.get('pid')
if not isinstance(expected_pid, int) or expected_pid <= 0:
    raise SystemExit(0)
command = subprocess.run(['ps', '-p', str(expected_pid), '-o', 'command='], capture_output=True, text=True).stdout
expected_token = str(root / (nonce + '.token'))
if command and nonce in command and expected_token in command and '--isolated' in command and 'serve' in command:
    try:
        os.kill(expected_pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
elif command:
    raise SystemExit(0)
for suffix in ('.token', '.log', '.json'):
    (root / (nonce + suffix)).unlink(missing_ok=True)
finish()
"""#
}
