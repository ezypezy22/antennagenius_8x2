import AppKit
import Combine
import UserNotifications

// MARK: - Change history, time per band and antenna, and notifications

struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case antenna, band, source, connection, cat, message }
    var id = UUID()
    let at: Date
    /// 1 = Radio A, 2 = Radio B, nil = the whole unit.
    let radio: Int?
    let kind: Kind
    let text: String
    /// Who asked for it: "This app", "Preset “…”", "Link", "CAT"; nil = elsewhere (FlexRadio, another client, front panel).
    let origin: String?
}

/// Seconds a band or antenna was in use, and how many of those the radio was transmitting.
struct UsageCounter: Codable, Equatable {
    var on: Double = 0
    var tx: Double = 0
}

/// One radio's usage on one day, by band and antenna name.
struct UsageDay: Codable, Equatable {
    var bands: [String: UsageCounter] = [:]
    var antennas: [String: UsageCounter] = [:]

    /// Adds `dt` seconds of the port's current state. The device has no power or SWR sensors, so transmit time
    /// comes from its `tx` flag: the radio is keyed on that port.
    mutating func add(_ dt: Double, port p: PortState, band: String, antenna: (Int) -> String) {
        bands[band, default: UsageCounter()].on += dt
        if p.tx { bands[band, default: UsageCounter()].tx += dt }
        for a in Set([p.rxant, p.txant]) where a > 0 { antennas[antenna(a), default: UsageCounter()].on += dt }
        if p.tx && p.txant > 0 { antennas[antenna(p.txant), default: UsageCounter()].tx += dt }
    }

    mutating func merge(_ o: UsageDay) {
        for (k, v) in o.bands { bands[k, default: UsageCounter()].on += v.on; bands[k, default: UsageCounter()].tx += v.tx }
        for (k, v) in o.antennas { antennas[k, default: UsageCounter()].on += v.on; antennas[k, default: UsageCounter()].tx += v.tx }
    }
}

/// Device serial → day (yyyy-MM-dd, local) → radio port ("1"/"2") → usage.
typealias UsageBook = [String: [String: [String: UsageDay]]]

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days", all = "All time"
    var id: String { rawValue }
    var days: Int? { self == .today ? 1 : self == .week ? 7 : self == .month ? 30 : nil }
}

@MainActor
final class ActivityStore: ObservableObject {
    static let shared = ActivityStore()
    static let historyLimit = 5000

    @Published private(set) var history: [HistoryEntry] = []
    @Published var usage: UsageBook = [:]

    private weak var client: AGClient?
    private weak var cat: CatManager?
    private var bag: Set<AnyCancellable> = []
    private var tickTimer: Timer?
    private var lastTick: Date?
    private var dirty = false
    private var lastSave = Date()
    private var lastState: ConnectionState = .disconnected
    private var offlineWork: DispatchWorkItem?
    private var notifiedOffline = false
    private var catLost: [Int: (since: Date, notified: Bool)] = [:]
    private let dir: URL?

    init(directory: URL? = ActivityStore.defaultDirectory) {
        dir = directory
        if let dir {
            let dec = JSONDecoder()
            if let d = try? Data(contentsOf: dir.appendingPathComponent("history.json")),
               let h = try? dec.decode([HistoryEntry].self, from: d) { history = h }
            if let d = try? Data(contentsOf: dir.appendingPathComponent("usage.json")),
               let u = try? dec.decode(UsageBook.self, from: d) { usage = u }
        }
    }

    nonisolated static var defaultDirectory: URL? {
        // Tests and `swift run` have no app bundle; they keep nothing on disk.
        guard Bundle.main.bundleURL.pathExtension == "app",
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("Antenna Genius", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func attach(_ c: AGClient, cat: CatManager) {
        guard client == nil else { return }
        client = c
        self.cat = cat
        c.portObservers.append { [weak self] old, new, origin in self?.portChanged(old, new, origin) }
        c.$state.sink { [weak self] s in self?.stateChanged(s) }.store(in: &bag)
        c.$lastError.compactMap { $0 }.sink { [weak self] m in self?.add(nil, .message, m, origin: nil) }.store(in: &bag)
        cat.$status.sink { [weak self] s in self?.catChanged(s) }.store(in: &bag)
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ActivityStore.shared.tick() }
        }
        Notifier.prepare()
    }

    // MARK: History

    func add(_ radio: Int?, _ kind: HistoryEntry.Kind, _ text: String, origin: String?, at: Date = Date()) {
        history.append(HistoryEntry(at: at, radio: radio, kind: kind, text: text, origin: origin))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        dirty = true
    }

    func clearHistory() { history = []; dirty = true; save() }
    func resetUsage() { usage = [:]; dirty = true; save() }

    /// What changed on a port, in words; TX keying alone is not history (it shows in the usage figures).
    static func describe(old: PortState, new: PortState, antenna: (Int) -> String, band: (Int) -> String) -> [(HistoryEntry.Kind, String)] {
        var out: [(HistoryEntry.Kind, String)] = []
        if old.rxant != new.rxant || old.txant != new.txant {
            if new.rxant == new.txant {
                out.append((.antenna, new.rxant == 0 ? "Released (no antenna)" : "Antenna → \(antenna(new.rxant))"))
            } else {
                out.append((.antenna, "RX → \(new.rxant == 0 ? "none" : antenna(new.rxant)), TX → \(new.txant == 0 ? "none" : antenna(new.txant))"))
            }
        }
        if old.band != new.band { out.append((.band, "Band → \(band(new.band))")) }
        if old.source != new.source && !new.source.isEmpty { out.append((.source, "Source → \(new.source)")) }
        return out
    }

    private func portChanged(_ old: PortState, _ new: PortState, _ origin: String?) {
        guard let c = client else { return }
        for (kind, text) in Self.describe(old: old, new: new, antenna: c.antennaName, band: c.bandName(id:)) {
            add(new.id, kind, text, origin: origin)
        }
    }

    private func stateChanged(_ s: ConnectionState) {
        defer { lastState = s }
        guard let c = client, s != lastState else { return }
        let name = c.deviceName.isEmpty ? (c.connectedDevice?.name ?? c.lastDevice?.name ?? "the device") : c.deviceName
        switch s {
        case .connected:
            add(nil, .connection, "Connected to \(c.connectedDevice?.name ?? name)", origin: nil)
            offlineWork?.cancel(); offlineWork = nil
            if notifiedOffline {
                notifiedOffline = false
                Notifier.post(.device, "Antenna Genius is back online", "\(c.connectedDevice?.name ?? name) is connected again.")
            }
        case .failed(let why):
            guard lastState == .connected else { return }
            add(nil, .connection, "Connection lost: \(why)", origin: nil)
            // Only tell the user if it stays down (a reboot takes about 20 s, a blip less), and not after their own reboot.
            guard c.autoConnect, !c.restartExpected else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.client?.state != .connected else { return }
                    self.notifiedOffline = true
                    Notifier.post(.device, "Antenna Genius is offline", "\(name): \(why)")
                }
            }
            offlineWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        case .disconnected:
            if lastState == .connected { add(nil, .connection, "Disconnected", origin: "This app") }
        case .connecting:
            break
        }
    }

    /// A CAT link that stays down 10 s is history and a notification; its recovery too, once it was reported.
    private func catChanged(_ status: [Int: CatStatus]) {
        for id in 1...2 {
            let err = status[id]?.error
            if let err {
                if catLost[id] == nil { catLost[id] = (Date(), false) }
                if let lost = catLost[id], !lost.notified, Date().timeIntervalSince(lost.since) >= 10 {
                    catLost[id]?.notified = true
                    add(id, .cat, "CAT lost: \(err)", origin: "CAT")
                    Notifier.post(.cat, "CAT lost Radio \(id == 1 ? "A" : "B")", err)
                }
            } else if let lost = catLost.removeValue(forKey: id), lost.notified {
                add(id, .cat, "CAT back", origin: "CAT")
                Notifier.post(.cat, "CAT is back for Radio \(id == 1 ? "A" : "B")", "The band follows the radio again.")
            }
        }
    }

    // MARK: Usage

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ d: Date) -> String { dayFormat.string(from: d) }

    private func tick() {
        let now = Date()
        defer { lastTick = now }
        if let cat { catChanged(cat.status) }   // a link that stays down publishes nothing new
        guard let c = client, c.state == .connected, let serial = c.connectedDevice?.serial, let last = lastTick else { return }
        let dt = min(now.timeIntervalSince(last), 2)   // after sleep, don't count the gap
        let day = Self.dayKey(now)
        for p in c.ports {
            usage[serial, default: [:]][day, default: [:]][String(p.id), default: UsageDay()]
                .add(dt, port: p, band: c.bandName(id: p.band), antenna: c.antennaName)
        }
        dirty = true
        if now.timeIntervalSince(lastSave) > 60 { save() }
    }

    /// Usage for one radio (or both, nil) over a period, for the unit that is connected (or all units).
    func totals(serial: String?, radio: Int?, period: UsagePeriod, now: Date = Date()) -> UsageDay {
        let cutoff = period.days.flatMap { Calendar.current.date(byAdding: .day, value: -($0 - 1), to: now) }.map(Self.dayKey)
        var sum = UsageDay()
        for (s, days) in usage where serial == nil || s == serial {
            for (day, ports) in days where cutoff == nil || day >= cutoff! {
                for (port, u) in ports where radio == nil || port == String(radio!) { sum.merge(u) }
            }
        }
        return sum
    }

    // MARK: Saving

    func save() {
        guard dirty, let dir else { return }
        dirty = false
        lastSave = Date()
        let enc = JSONEncoder()
        try? enc.encode(history).write(to: dir.appendingPathComponent("history.json"), options: .atomic)
        try? enc.encode(usage).write(to: dir.appendingPathComponent("usage.json"), options: .atomic)
    }

    func csv() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return (["time,radio,change,by"] + history.map { e in
            [f.string(from: e.at), e.radio.map { $0 == 1 ? "A" : "B" } ?? "", q(e.text), q(e.origin ?? "Elsewhere")].joined(separator: ",")
        }).joined(separator: "\n") + "\n"
    }
}

extension AGClient {
    func antennaName(_ id: Int) -> String { antennas.first { $0.id == id }?.name ?? "Antenna \(id)" }
    func bandName(id: Int) -> String { id == 0 ? "None" : bands.first { $0.id == id }?.name ?? "Band \(id)" }
}

// MARK: - Notifications

enum Notifier {
    enum Topic: String { case device = "notify.device", cat = "notify.cat" }

    /// Only inside the app bundle: the notification center needs one (tests and `swift run` have none).
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func enabled(_ t: Topic) -> Bool { UserDefaults.standard.object(forKey: t.rawValue) as? Bool ?? true }

    static func prepare() {
        guard available, enabled(.device) || enabled(.cat) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ t: Topic, _ title: String, _ body: String) {
        guard available, enabled(t) else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let center = UNUserNotificationCenter.current()
        // Asks once (macOS remembers the answer), then posts if allowed.
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
