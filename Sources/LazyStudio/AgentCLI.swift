import Foundation

/// Auto-detects AI coding agent CLIs installed on this Mac (Claude Code, Codex,
/// Gemini) and uses them as the editing brain — no API keys, no accounts.
/// Your existing subscription just works.
struct AgentCLI: Identifiable, Sendable {
    let id: String          // "claude", "codex", "gemini"
    let displayName: String
    let path: String

    private static let candidates: [(id: String, name: String, binary: String)] = [
        ("claude", "Claude Code", "claude"),
        ("codex", "Codex", "codex"),
        ("gemini", "Gemini", "gemini"),
    ]

    private static let searchDirs = [
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.claude/local",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.npm-global/bin",
        "\(NSHomeDirectory())/bin",
    ]

    /// GUI apps don't inherit the shell PATH, so scan known install dirs
    /// and fall back to a login-shell `which`.
    static func detectAll() -> [AgentCLI] {
        candidates.compactMap { c in
            for dir in searchDirs {
                let p = "\(dir)/\(c.binary)"
                if FileManager.default.isExecutableFile(atPath: p) {
                    return AgentCLI(id: c.id, displayName: c.name, path: p)
                }
            }
            if let p = shellWhich(c.binary) {
                return AgentCLI(id: c.id, displayName: c.name, path: p)
            }
            return nil
        }
    }

    private static func shellWhich(_ binary: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "command -v \(binary)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Run a one-shot prompt through this agent and return its text output.
    func run(prompt: String) async throws -> String {
        let args: [String]
        switch id {
        case "claude": args = ["-p", prompt]
        case "codex":  args = ["exec", "--skip-git-repo-check", prompt]
        default:       args = ["-p", prompt]
        }

        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            proc.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
            proc.environment = env

            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice

            proc.terminationHandler = { p in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                if p.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: AgentError.failed(text))
                }
            }
            do { try proc.run() } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum AgentError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let out) = self {
                return "Agent CLI failed: \(out.prefix(200))"
            }
            return nil
        }
    }
}
