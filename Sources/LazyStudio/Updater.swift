import Foundation
import AppKit

/// Simple, transparent auto-updater backed by GitHub Releases.
/// Checks once a day (and on demand), downloads the new LazyStudio.zip,
/// swaps /Applications/LazyStudio.app, and relaunches.
@MainActor
final class Updater: ObservableObject {
    static let repo = "everyai-com/lazystudio"

    @Published var status = ""
    @Published var updateAvailable: String?
    @Published var isWorking = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkAutomatically() {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task { await check(quiet: true) }
    }

    func check(quiet: Bool = false) async {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        if !quiet { status = "Checking…" }
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Release: Decodable {
                let tag_name: String
                let assets: [Asset]
                struct Asset: Decodable { let name: String; let browser_download_url: String }
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if isNewer(latest, than: currentVersion) {
                updateAvailable = latest
                status = "Version \(latest) available"
            } else {
                updateAvailable = nil
                if !quiet { status = "Up to date (\(currentVersion))" }
            }
        } catch {
            if !quiet { status = "Update check failed" }
        }
    }

    func installUpdate() async {
        guard let version = updateAvailable, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        status = "Downloading \(version)…"
        do {
            let zipURL = URL(string:
                "https://github.com/\(Self.repo)/releases/download/v\(version)/LazyStudio.zip")!
            let (tmp, _) = try await URLSession.shared.download(from: zipURL)

            status = "Installing…"
            let unzipDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("LazyStudio-update-\(version)")
            try? FileManager.default.removeItem(at: unzipDir)
            try run("/usr/bin/ditto", "-x", "-k", tmp.path, unzipDir.path)

            let newApp = unzipDir.appendingPathComponent("LazyStudio.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                status = "Bad update package"
                return
            }
            let dest = "/Applications/LazyStudio.app"
            try? FileManager.default.removeItem(atPath: dest)
            try run("/usr/bin/ditto", newApp.path, dest)

            status = "Relaunching…"
            // Relaunch AFTER this instance is gone — launching first trips
            // the new copy's single-instance guard and both quit.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 2; /usr/bin/open '\(dest)'"]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            status = "Update failed: \(error.localizedDescription)"
        }
    }

    private func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func run(_ cmd: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Updater", code: Int(p.terminationStatus))
        }
    }
}
