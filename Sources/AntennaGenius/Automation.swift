import AppKit

// MARK: - agenius:// links, for Stream Deck, Shortcuts ("Open URLs") and scripts (`open "agenius://…"`)
//
//   agenius://select?radio=A&antenna=3        antenna by number or by name (antenna=Yagi)
//   agenius://release?radio=B
//   agenius://preset?name=Contest
//
// Add focus=1 to bring the app forward; otherwise focus goes back to the app you were using.

enum AutomationCommand: Equatable {
    enum Antenna: Equatable { case number(Int), name(String) }
    case select(port: Int, antenna: Antenna)
    case release(port: Int)
    case preset(name: String)
}

@MainActor
final class Automation {
    nonisolated static let scheme = "agenius"
    static let shared = Automation()
    weak var client: AGClient?

    /// A command that arrived before the device was connected (e.g. the link launched the app).
    private var pending: (cmd: AutomationCommand, until: Date)?
    private var pendingTimer: Timer?
    /// The last other app that was in front, and when this app last became active.
    private var previousApp: NSRunningApplication?
    private var activatedAt = Date.distantPast

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    Automation.shared.activatedAt = Date()
                } else if let app {
                    Automation.shared.previousApp = app
                }
            }
        }
    }

    static func parse(_ url: URL) -> Result<AutomationCommand, AutomationError> {
        guard url.scheme?.lowercased() == scheme, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(AutomationError("Not an \(scheme):// link."))
        }
        // agenius://select?… has the action as host; agenius:select?… as path.
        let action = (c.host ?? c.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name.lowercased()] = item.value ?? "" }

        func port() -> Result<Int, AutomationError> {
            switch (q["radio"] ?? q["port"] ?? "").uppercased() {
            case "A", "1": return .success(1)
            case "B", "2": return .success(2)
            default: return .failure(AutomationError("Say which radio: radio=A or radio=B."))
            }
        }
        switch action {
        case "select":
            guard let a = q["antenna"]?.trimmingCharacters(in: .whitespaces), !a.isEmpty else {
                return .failure(AutomationError("Say which antenna: antenna=3 or antenna=<name>."))
            }
            return port().map { .select(port: $0, antenna: Int(a).map { .number($0) } ?? .name(a)) }
        case "release":
            return port().map { .release(port: $0) }
        case "preset":
            guard let n = q["name"], !n.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(AutomationError("Say which preset: preset?name=<name>."))
            }
            return .success(.preset(name: n))
        default:
            return .failure(AutomationError("Unknown action “\(action)”. Use select, release or preset."))
        }
    }

    func handle(_ url: URL) {
        let wantsFocus = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name.lowercased() == "focus" && $0.value == "1" } ?? false
        // Opening the link brought this app forward; hand focus back (e.g. to the logger) unless asked not to.
        if !wantsFocus, Date().timeIntervalSince(activatedAt) < 1.5, let prev = previousApp, !prev.isTerminated {
            prev.activate()
        }
        switch Self.parse(url) {
        case .failure(let e): report(e.message)
        case .success(let cmd):
            guard let client, client.state == .connected, !client.bands.isEmpty else {
                pending = (cmd, Date().addingTimeInterval(30))
                waitForConnection()
                return
            }
            run(cmd, on: client)
        }
    }

    private func waitForConnection() {
        guard pendingTimer == nil else { return }
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let a = Automation.shared
                guard let p = a.pending else { a.stopWaiting(); return }
                if let c = a.client, c.state == .connected, !c.bands.isEmpty {
                    a.stopWaiting(); a.run(p.cmd, on: c)
                } else if Date() > p.until {
                    a.stopWaiting(); a.report("A link arrived but no Antenna Genius was connected within 30 seconds.")
                }
            }
        }
    }

    private func stopWaiting() {
        pendingTimer?.invalidate(); pendingTimer = nil
        pending = nil
    }

    private func run(_ cmd: AutomationCommand, on client: AGClient) {
        switch cmd {
        case .preset(let name):
            guard let p = PresetStore.shared.preset(named: name) else { return report("No preset is called “\(name)”.") }
            client.apply(preset: p)
        case .release(let port):
            guard !transmitting(port, client) else { return }
            client.withOrigin("Link") { client.clearAntenna(port: port) }
        case .select(let port, let ref):
            guard let id = Self.antennaID(ref, in: client.antennas) else {
                if case .name(let n) = ref { return report("No antenna is called “\(n)”.") }
                return report("There is no antenna \(ref).")
            }
            guard !transmitting(port, client) else { return }
            client.withOrigin("Link") { client.selectAntenna(port: port, antenna: id) }
        }
    }

    /// Links never switch a radio that is transmitting.
    private func transmitting(_ port: Int, _ client: AGClient) -> Bool {
        guard client.ports.first(where: { $0.id == port })?.tx == true else { return false }
        report("Radio \(port == 1 ? "A" : "B") is transmitting, so the link didn't switch it.")
        return true
    }

    static func antennaID(_ ref: AutomationCommand.Antenna, in antennas: [AntennaInfo]) -> Int? {
        switch ref {
        case .number(let n): return antennas.contains { $0.id == n } ? n : nil
        case .name(let s): return antennas.first { PresetStore.key($0.name) == PresetStore.key(s) }?.id
        }
    }

    private func report(_ message: String) {
        client?.lastError = message
        NSSound.beep()
    }
}

struct AutomationError: Error, Equatable {
    let message: String
    init(_ m: String) { message = m }
}
