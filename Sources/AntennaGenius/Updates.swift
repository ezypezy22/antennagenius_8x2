import AppKit
import SwiftUI

/// Looks for a newer release on GitHub: at launch and every 24 hours while running (unless turned off), and
/// from the menu. A newer release stays in `available`, which the main window shows as a banner until it is installed.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    private static let releasesAPI = URL(string: "https://api.github.com/repos/ezypezy22/antennagenius_8x2/releases?per_page=20")!

    struct Release: Equatable {
        let version: String
        let page: URL
    }

    /// A release newer than this copy, once a check has found one.
    @Published private(set) var available: Release?
    private var busy = false
    private var timer: Timer?
    /// Versions already offered in a pop-up this run, so the 24-hour check doesn't ask again; the banner stays.
    private var offered: Set<String> = []

    /// Checks now and then every 24 hours for as long as the app runs.
    func startSchedule() {
        Task { await checkAutomatically() }
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.checkAutomatically() }
        }
    }

    private func checkAutomatically() async {
        guard UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true else { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let latest: Release?
        do {
            latest = try await fetchLatest()
        } catch {
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
            return
        }
        guard let latest, Self.isNewer(latest.version, than: AppInfo.version) else {
            if userInitiated { alert("You're up to date", "Antenna Genius \(AppInfo.version) is the newest version.") }
            return
        }
        available = latest
        // Skipped, or already offered this run: only the banner, unless the user asked.
        if !userInitiated, UserDefaults.standard.string(forKey: "skippedVersion") == latest.version
            || offered.contains(latest.version) { return }
        offered.insert(latest.version)
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
        a.informativeText = "You have \(AppInfo.version). The release page has the download and what changed. Until you install it, the main window shows that an update is available."
        a.addButton(withTitle: "Open Release Page")
        a.addButton(withTitle: "Later")
        if !userInitiated { a.addButton(withTitle: "Skip This Version") }
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(r.page)
        case .alertThirdButtonReturn: UserDefaults.standard.set(r.version, forKey: "skippedVersion")   // no more pop-ups for it
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

/// Shown at the bottom of the main window while a newer release is available.
struct UpdateBanner: View {
    let release: UpdateChecker.Release

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.radioB)
            Text("Version \(release.version) is available").font(.system(size: Theme.fs(11), weight: .semibold))
                .foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button("Get") { NSWorkspace.shared.open(release.page) }.controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Theme.chrome)
        .help("Opens the release page for Antenna Genius \(release.version)")
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
