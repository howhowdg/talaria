import Foundation

public struct RuntimeCandidate: Sendable, Equatable, Identifiable {
    public let executableURL: URL
    public let arguments: [String]
    public let label: String
    public var id: String { executableURL.path + arguments.joined(separator: " ") }

    public init(executableURL: URL, arguments: [String] = [], label: String) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.label = label
    }
}

/// Metadata-only discovery. Candidates still require an actual launch/readiness check.
/// This never executes a candidate, loads a shell profile, or reads Hermes credentials.
public enum RuntimeDiscovery {
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [RuntimeCandidate] {
        let hermesHome = environment["HERMES_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".hermes", isDirectory: true)
        var paths: [RuntimeCandidate] = []
        if let override = environment["HERMES_DESKTOP_HERMES"], override.hasPrefix("/") {
            paths.append(RuntimeCandidate(executableURL: URL(fileURLWithPath: override), label: "Configured Hermes CLI"))
        }
        for directory in ["venv", ".venv"] {
            let interpreter = hermesHome.appendingPathComponent("hermes-agent/\(directory)/bin/python")
            paths.append(RuntimeCandidate(executableURL: interpreter, arguments: ["-m", "hermes_cli.main"], label: "Managed Hermes Python"))
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [homeDirectory.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories where directory.hasPrefix("/") {
            paths.append(RuntimeCandidate(executableURL: URL(fileURLWithPath: directory).appendingPathComponent("hermes"), label: "Hermes CLI"))
        }
        var seen = Set<String>()
        return paths.filter {
            FileManager.default.isExecutableFile(atPath: $0.executableURL.path)
                && seen.insert($0.executableURL.standardizedFileURL.path).inserted
        }
    }
}
