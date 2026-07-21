import Foundation
import Network
@preconcurrency import AVFoundation
import AppKit

/// Local MCP server (Palmier-style): Claude Code / Codex connect to
/// http://127.0.0.1:19790/mcp and edit your videos with small tools —
/// the strip in the app updates live. Localhost only.
@MainActor
final class MCPServer {
    static let shared = MCPServer()
    static let port: UInt16 = 19790
    weak var recorder: RecorderEngine?
    private var listener: NWListener?

    func start(recorder: RecorderEngine) {
        self.recorder = recorder
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!
            )
            let l = try NWListener(using: params)
            l.newConnectionHandler = { conn in
                Task { @MainActor in self.serve(conn) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            NSLog("MCP server failed to start: \(error)")
        }
    }

    // MARK: - HTTP plumbing (single POST endpoint, JSON in/out)

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            Task { @MainActor in
                var buf = buffer
                if let data { buf.append(data) }
                if error != nil { conn.cancel(); return }
                if let request = Self.completeRequest(buf) {
                    let body = await self.handle(request)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: head.data(using: .utf8)! + body,
                              completion: .contentProcessed { _ in conn.cancel() })
                } else if done {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }

    /// Returns the body once headers + full Content-Length are in.
    private static func completeRequest(_ data: Data) -> Data? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let len = head.lowercased()
            .split(separator: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[headerEnd.upperBound...]
        return body.count >= len ? Data(body.prefix(len)) : nil
    }

    // MARK: - JSON-RPC / MCP

    private func handle(_ body: Data) async -> Data {
        guard let req = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = req["method"] as? String else {
            return Data("{}".utf8)
        }
        let id = req["id"]
        let params = req["params"] as? [String: Any] ?? [:]

        func reply(_ result: Any) -> Data {
            var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
            if let id { msg["id"] = id }
            return (try? JSONSerialization.data(withJSONObject: msg)) ?? Data("{}".utf8)
        }

        switch method {
        case "initialize":
            return reply([
                "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "lazystudio", "version": "1.0"],
            ])
        case "notifications/initialized", "ping":
            return reply([:] as [String: Any])
        case "tools/list":
            return reply(["tools": Self.toolDefs])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let content = await call(tool: name, args: args)
            return reply(["content": content])
        default:
            return reply([:] as [String: Any])
        }
    }

    private static let toolDefs: [[String: Any]] = [
        ["name": "list_videos",
         "description": "List all LazyStudio recordings, newest first: file name, date, duration in seconds, whether it's a raw recording or an edited export.",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
        ["name": "get_transcript",
         "description": "On-device speech transcript of a video as timestamped lines. Use the exact file name from list_videos.",
         "inputSchema": ["type": "object",
                         "properties": ["video": ["type": "string", "description": "file name from list_videos"]],
                         "required": ["video"]]],
        ["name": "get_timeline",
         "description": "Current keep/cut plan of the video open in the LazyStudio editor: segments with start, end, kept; plus kept vs total seconds.",
         "inputSchema": ["type": "object",
                         "properties": ["video": ["type": "string"]],
                         "required": ["video"]]],
        ["name": "set_keep_ranges",
         "description": "Replace the cut plan for a video with keep-ranges (seconds). The editor strip in the app updates live. Returns the resulting delta. Ranges must be ascending and non-overlapping.",
         "inputSchema": ["type": "object",
                         "properties": [
                            "video": ["type": "string"],
                            "ranges": ["type": "array",
                                       "items": ["type": "array",
                                                 "items": ["type": "number"],
                                                 "minItems": 2, "maxItems": 2]],
                         ],
                         "required": ["video", "ranges"]]],
        ["name": "capture_frame",
         "description": "Capture a PNG frame of the video at a timestamp (seconds) so you can see the visuals.",
         "inputSchema": ["type": "object",
                         "properties": ["video": ["type": "string"],
                                        "time": ["type": "number"]],
                         "required": ["video", "time"]]],
        ["name": "ai_edit",
         "description": "Run LazyStudio's built-in AI edit on a video: transcribe, plan cuts with the user's configured agent, and apply them to the live editor. Optional instruction guides the edit.",
         "inputSchema": ["type": "object",
                         "properties": ["video": ["type": "string"],
                                        "instruction": ["type": "string"]],
                         "required": ["video"]]],
        ["name": "export_video",
         "description": "Render the current keep/cut plan of this video to <name>.edited.mp4 and return its path.",
         "inputSchema": ["type": "object",
                         "properties": ["video": ["type": "string"]],
                         "required": ["video"]]],
    ]

    private func url(for name: String) -> URL? {
        guard let dir = recorder?.recordingsDirectory else { return nil }
        let candidate = dir.appendingPathComponent(name)
        guard candidate.pathExtension == "mp4",
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func text(_ s: String) -> [[String: Any]] {
        [["type": "text", "text": s]]
    }

    private func call(tool: String, args: [String: Any]) async -> [[String: Any]] {
        switch tool {
        case "list_videos":
            guard let dir = recorder?.recordingsDirectory else { return text("No recorder") }
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "mp4" }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return a > b
                }
            var lines: [String] = []
            for f in files.prefix(30) {
                let d = (try? await CMTimeGetSeconds(AVURLAsset(url: f).load(.duration))) ?? 0
                let kind = f.lastPathComponent.contains("edited") || f.lastPathComponent.contains("polished") ? "edited" : "raw"
                lines.append("\(f.lastPathComponent) · \(Int(d))s · \(kind)")
            }
            return text(lines.isEmpty ? "No recordings yet." : lines.joined(separator: "\n"))

        case "get_transcript":
            guard let u = url(for: args["video"] as? String ?? "") else { return text("Video not found") }
            do {
                let segs = try await Transcriber.transcribe(url: u)
                return text(segs.isEmpty ? "(no speech)" : Transcriber.promptText(from: segs))
            } catch { return text("Transcription failed: \(error.localizedDescription)") }

        case "get_timeline":
            guard let u = url(for: args["video"] as? String ?? "") else { return text("Video not found") }
            if let s = LibraryView.activeSession, s.url == u {
                let rows = s.segments.map {
                    String(format: "%.2f–%.2f %@", $0.start, $0.end, $0.kept ? "KEEP" : "cut")
                }
                return text(rows.joined(separator: "\n")
                    + String(format: "\nkept %.1fs of %.1fs", s.keptDuration, s.duration))
            }
            let d = (try? await CMTimeGetSeconds(AVURLAsset(url: u).load(.duration))) ?? 0
            return text(String(format: "0.00–%.2f KEEP (no cuts yet)\nkept %.1fs of %.1fs", d, d, d))

        case "set_keep_ranges":
            guard let u = url(for: args["video"] as? String ?? "") else { return text("Video not found") }
            // Models send ranges as [[0,10]] OR [{"start":0,"end":10}] —
            // accept both; rejecting a valid edit over shape is how
            // "the AI isn't working" happens.
            var ranges: [AIEditor.EditPlan.Range] = []
            if let raw = args["ranges"] as? [[Any]] {
                ranges = raw.compactMap { pair in
                    guard pair.count == 2,
                          let a = (pair[0] as? NSNumber)?.doubleValue,
                          let b = (pair[1] as? NSNumber)?.doubleValue, b > a else { return nil }
                    return .init(start: a, end: b)
                }
            } else if let raw = args["ranges"] as? [[String: Any]] {
                ranges = raw.compactMap { dict in
                    guard let a = (dict["start"] as? NSNumber)?.doubleValue,
                          let b = (dict["end"] as? NSNumber)?.doubleValue, b > a else { return nil }
                    return .init(start: a, end: b)
                }
            }
            guard !ranges.isEmpty else {
                return text("Bad ranges — send [[startSec, endSec], …] or [{\"start\":s,\"end\":e}, …] with end > start")
            }
            let session: EditSession
            if let s = LibraryView.activeSession, s.url == u {
                session = s
            } else {
                session = EditSession(url: u)
                await session.load()
                LibraryView.adopt(session: session)
            }
            let before = session.keptDuration
            await session.apply(keep: ranges)
            NSApp.activate(ignoringOtherApps: true)
            return text(String(format: "Applied. kept %.1fs → %.1fs (of %.1fs). The app strip is updated.",
                               before, session.keptDuration, session.duration))

        case "capture_frame":
            guard let u = url(for: args["video"] as? String ?? "") else { return text("Video not found") }
            let t = (args["time"] as? NSNumber)?.doubleValue ?? 0
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: u))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 800, height: 800)
            guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            else { return text("Couldn't capture frame") }
            return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]

        case "ai_edit":
            guard let u = url(for: args["video"] as? String ?? "") else { return text("Video not found") }
            guard let recorder, let agent = recorder.activeAgent else {
                return text("No AI agent installed/selected")
            }
            let session: EditSession
            if let s = LibraryView.activeSession, s.url == u {
                session = s
            } else {
                session = EditSession(url: u)
                await session.load()
                LibraryView.adopt(session: session)
            }
            do {
                let plan = try await recorder.aiEditor.makePlan(
                    url: u, agent: agent,
                    instruction: args["instruction"] as? String
                )
                await session.apply(keep: plan.keep, cuts: plan.cuts)
                let cutList = (plan.cuts ?? []).map {
                    String(format: "%.1f-%.1f %@", $0.start, $0.end, $0.reason)
                }.joined(separator: "; ")
                return text(String(format: "Edited with %@. kept %.1fs of %.1fs. cuts: %@. title: %@",
                                   agent.displayName, session.keptDuration,
                                   session.duration, cutList, plan.title))
            } catch {
                return text("AI edit failed: \(error.localizedDescription)")
            }

        case "export_video":
            guard let u = url(for: args["video"] as? String ?? "") else { return text("Video not found") }
            let session: EditSession
            if let s = LibraryView.activeSession, s.url == u { session = s }
            else { session = EditSession(url: u); await session.load() }
            do {
                let out = try await session.export()
                return text("Exported: \(out.path)")
            } catch { return text("Export failed: \(error.localizedDescription)") }

        default:
            return text("Unknown tool \(tool)")
        }
    }
}
