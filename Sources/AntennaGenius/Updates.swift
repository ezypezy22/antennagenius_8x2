import AppKit
import SwiftUI

/// Looks for a newer release on GitHub: once a day at launch (unless turned off), and from the menu.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private static let releasesAPI = URL(string: "https://api.github.com/repos/ezypezy22/antennagenius_8x2/releases?per_page=20")!

    struct Release: Equatable {
        let version: String
        let page: URL
    }

    private var busy = false

    func checkAutomatically() async {
        let d = UserDefaults.standard
        guard d.object(forKey: "checkForUpdates") as? Bool ?? true else { return }
        if let last = d.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let latest: Release?
        do {
            latest = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        } catch {
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
            return
        }
        guard let latest, Self.isNewer(latest.version, than: AppInfo.version) else {
            if userInitiated { alert("You're up to date", "Antenna Genius \(AppInfo.version) is the newest version.") }
            return
        }
        // A version the user chose to skip only comes back when they ask.
        if !userInitiated, UserDefaults.standard.string(forKey: "skippedVersion") == latest.version { return }
        offer(latest, userInitiated: userInitiated)
    }

    private func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AntennaGenius/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "GitHub answered with HTTP \(http.statusCode)."])
        }
        return Self.newest(in: data)
    }

    /// The highest-versioned published release. Its version is read from the tag, else from a DMG's file name
    /// (e.g. `AntennaGenius-26.11.2-macos-universal.dmg`), so a release tagged `public` still counts.
    static func newest(in json: Data) -> Release? {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
        var best: Release?
        for r in list where r["draft"] as? Bool != true && r["prerelease"] as? Bool != true {
            let assets = (r["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            guard let v = version(in: [r["tag_name"] as? String ?? ""] + assets),
                  let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
            if best == nil || isNewer(v, than: best!.version) { best = Release(version: v, page: page) }
        }
        return best
    }

    static func version(in candidates: [String]) -> String? {
        for s in candidates {
            if let m = s.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) { return String(s[m]) }
        }
        return nil
    }

    /// Compares dotted numbers (26.11.10 is newer than 26.11.9). A non-numeric current version ("dev") is never current.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").compactMap { Int($0) }
        guard !y.isEmpty else { return true }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func offer(_ r: Release, userInitiated: Bool) {
        let a = NSAlert()
        a.messageText = "Antenna Genius \(r.version) is available"
        a.informativeText = "You have \(AppInfo.version). The release page has the download and what changed."
        a.addButton(withTitle: "Open Release Page")
        a.addButton(withTitle: "Later")
        if !userInitiated { a.addButton(withTitle: "Skip This Version") }
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(r.page)
        case .alertThirdButtonReturn: UserDefaults.standard.set(r.version, forKey: "skippedVersion")
        default: break
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// "Check for Updates…" under the app menu's About item.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await UpdateChecker.shared.check(userInitiated: true) } }
        }
    }
}
