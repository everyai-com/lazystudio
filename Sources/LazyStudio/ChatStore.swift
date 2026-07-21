import Foundation

/// Global log so "it just did nothing" becomes diagnosable:
/// ~/Library/Logs/LazyStudio.log
func lslog(_ msg: String) {
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("LazyStudio.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Chat threads per video, persisted to disk — switching tabs or relaunching
/// the app never loses a conversation again.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    struct Msg: Codable, Identifiable {
        var id = UUID()
        let fromUser: Bool
        let text: String
        var activity: String?
    }

    @Published private(set) var threads: [String: [Msg]] = [:]
    @Published var lastVideo: String?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LazyStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chats.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [Msg]].self, from: data) {
            threads = decoded
        }
        lastVideo = UserDefaults.standard.string(forKey: "chatLastVideo")
    }

    func thread(for url: URL) -> [Msg] {
        threads[url.lastPathComponent] ?? []
    }

    func append(_ msg: Msg, for url: URL) {
        threads[url.lastPathComponent, default: []].append(msg)
        save()
    }

    func clear(for url: URL) {
        threads[url.lastPathComponent] = nil
        save()
    }

    func rememberVideo(_ url: URL) {
        lastVideo = url.lastPathComponent
        UserDefaults.standard.set(lastVideo, forKey: "chatLastVideo")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(threads) {
            try? data.write(to: fileURL)
        }
    }
}
