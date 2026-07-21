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

    /// Is this agent actually signed in? (Codex has a real status command;
    /// its exit code is always 0, so parse the text.)
    func isLoggedIn() async -> Bool {
        guard id == "codex" else { return true }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["login", "status"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return false }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let out = String(decoding: data, as: UTF8.self).lowercased()
                cont.resume(returning: !out.contains("not logged in"))
            }
        }
    }

    /// Run a one-shot prompt through this agent and return its text output.
    func run(prompt: String) async throws -> String {
        // Cheapest model where the flag is reliable; codex keeps its default —
        // a pinned model id that stops existing breaks every edit.
        let args: [String]
        switch id {
        case "claude": args = ["-p", "--model", "haiku", prompt]
        case "codex":  args = ["exec", "--skip-git-repo-check", prompt]
        case "gemini": args = ["-p", prompt, "-m", "gemini-2.5-flash"]
        default:       args = ["-p", prompt]
        }
        return try await runArgs(args)
    }

    /// Chat turn with LazyStudio's own MCP server attached — the agent can
    /// call set_keep_ranges etc. and the app updates live (Lovable-style).
    func chat(message: String, followUp: Bool) async throws -> String {
        let mcpJSON = #"{"mcpServers":{"lazystudio":{"type":"http","url":"http://127.0.0.1:19790/mcp"}}}"#
        var args: [String]
        switch id {
        case "claude":
            args = ["-p", message,
                    "--mcp-config", mcpJSON, "--strict-mcp-config",
                    "--dangerously-skip-permissions"]
            if followUp { args.append("--continue") }
        case "codex":
            args = ["exec", "--skip-git-repo-check",
                    "-c", "mcp_servers.lazystudio.url=\"http://127.0.0.1:19790/mcp\"",
                    message]
        default:
            args = ["-p", message]
        }
        let raw = try await runArgs(args)
        return Self.cleanChatOutput(raw)
    }

    /// Codex exec prefixes logs/banners; keep the substance.
    static func cleanChatOutput(_ raw: String) -> String {
        let junk = ["OpenAI Codex", "workdir:", "model:", "provider:", "approval:",
                    "sandbox:", "reasoning", "tokens used", "session id", "--------"]
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("[") { return false }
                return !junk.contains { l.localizedCaseInsensitiveContains($0) }
            }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runArgs(_ args: [String]) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            proc.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
            proc.environment = env

            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err

            do { try proc.run() } catch {
                continuation.resume(throwing: error)
                return
            }
            // Never hang forever — a stuck agent gets killed and reported.
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                if proc.isRunning { proc.terminate() }
            }
            // Drain both pipes WHILE the process runs — reading only after
            // exit deadlocks once output exceeds the 64KB pipe buffer.
            nonisolated(unsafe) var errData = Data()
            DispatchQueue.global(qos: .utility).async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                lslog("agent \(self.id): exit=\(proc.terminationStatus) out=\(text.count)ch err=\(errData.count)ch — \(String(decoding: errData.prefix(200), as: UTF8.self))")
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    var detail = text + "\n" + String(decoding: errData, as: UTF8.self)
                    detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    if detail.lowercased().contains("keychain")
                        || detail.lowercased().contains("credential")
                        || detail.lowercased().contains("logged out")
                        || detail.lowercased().contains("log in") {
                        detail += "\n→ The agent can't unlock its login from inside the app. If macOS shows a keychain prompt, click Always Allow."
                    }
                    continuation.resume(throwing: AgentError.failed(detail))
                }
            }
        }
    }

    enum AgentError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let out) = self {
                return "Agent CLI failed: \(out.suffix(400))"
            }
            return nil
        }
    }
}
