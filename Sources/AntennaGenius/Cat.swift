import Foundation
import Network

// MARK: - Band from the radio's CAT frequency (Hamlib rigctld or flrig)

/// Where one radio port gets its frequency from. Kept in the app's settings, not on the device.
struct CatConfig: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case off, rigctld, flrig
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .rigctld: return "Hamlib rigctld"
            case .flrig: return "flrig"
            }
        }
        var defaultPort: UInt16 { self == .flrig ? 12345 : 4532 }
    }
    var kind = Kind.off
    var host = "127.0.0.1"
    var port: UInt16 = 4532

    static func load(port id: Int) -> CatConfig {
        guard let data = UserDefaults.standard.data(forKey: "cat.port\(id)"),
              let c = try? JSONDecoder().decode(CatConfig.self, from: data) else { return CatConfig() }
        return c
    }

    func save(port id: Int) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "cat.port\(id)") }
    }
}

/// What the CAT link for one port is doing, for the panel and Settings.
struct CatStatus: Equatable {
    var hz: Int?
    var band: Int?
    var error: String?
    /// A band change is waiting for the radio to stop transmitting.
    var heldForTX = false
}

enum CatBand {
    /// The configured band (1–15) whose range holds the frequency; 0 ("None") if none does.
    static func band(forHz hz: Int, in bands: [BandInfo]) -> Int {
        for b in bands.sorted(by: { $0.id < $1.id }) where b.id > 0 {
            guard let lo = Double(b.freqStart), let hi = Double(b.freqStop), hi > 0 else { continue }
            let mhz = Double(hz) / 1_000_000
            if mhz >= lo && mhz <= hi { return b.id }
        }
        return 0
    }

    /// The band to send for this port, or nil when nothing needs sending. Never while the port transmits:
    /// a band change can move TX to another antenna, and switching under power can damage the switch or amplifier.
    static func bandToSend(target: Int, port: PortState) -> Int? {
        if port.tx { return nil }
        if port.band == target && port.source == "MANUAL" && !port.auto { return nil }
        return target
    }

    /// rigctld answers `f` with the frequency in Hz on one line, or `RPRT <negative code>` on error.
    static func parseRigctld(_ line: String) -> Int? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hz = Int(t) ?? Double(t).map({ Int($0) }), hz > 0 else { return nil }
        return hz
    }

    /// flrig answers `rig.get_vfo` with XML-RPC: `<value>14074000</value>`, possibly wrapped in `<string>`.
    static func parseFlrig(_ xml: String) -> Int? {
        guard !xml.contains("<fault>"),
              let r = xml.range(of: #"<value>\s*(?:<(?:string|i4|int)>)?\s*(\d+)"#, options: .regularExpression) else { return nil }
        return Int(xml[r].filter(\.isNumber))
    }
}

/// Asks the CAT program for the frequency twice a second and reports each answer (or failure) on the main queue.
@MainActor
protocol FrequencyPoller: AnyObject {
    func start(_ report: @escaping (Result<Int, CatError>) -> Void)
    func stop()
}

struct CatError: Error, Equatable {
    let message: String
}

/// Hamlib's rigctld: one TCP connection, `f\n` → `<Hz>\n`.
@MainActor
final class RigctldPoller: FrequencyPoller {
    private let host: String, port: UInt16
    private var conn: NWConnection?
    private var timer: Timer?
    private var buffer = ""
    private var awaiting: Date?
    private var report: ((Result<Int, CatError>) -> Void)?

    init(host: String, port: UInt16) { self.host = host; self.port = port }

    func start(_ report: @escaping (Result<Int, CatError>) -> Void) {
        self.report = report
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        conn?.cancel(); conn = nil
        report = nil
    }

    private func tick() {
        guard let c = conn else { connect(); return }
        if let since = awaiting {
            // No answer for 2 s: start over with a new connection.
            if Date().timeIntervalSince(since) > 2 { drop("rigctld at \(host):\(port) stopped answering.") }
            return
        }
        guard c.state == .ready else { return }
        awaiting = Date()
        c.send(content: Data("f\n".utf8), completion: .contentProcessed { _ in })
    }

    private func connect() {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        conn = c
        buffer = ""; awaiting = nil
        c.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated {
                guard let self, c === self.conn else { return }
                switch s {
                case .failed(let e), .waiting(let e): self.drop("Can't reach rigctld at \(self.host):\(self.port) (\(Self.reason(e))).")
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, c === self.conn else { return }
                if let data { self.buffer += String(decoding: data, as: UTF8.self) }
                while let nl = self.buffer.firstIndex(of: "\n") {
                    let line = String(self.buffer[..<nl])
                    self.buffer.removeSubrange(...nl)
                    self.awaiting = nil
                    if let hz = CatBand.parseRigctld(line) { self.report?(.success(hz)) }
                    else { self.report?(.failure(CatError(message: "rigctld answered “\(line)”."))) }
                }
                if let error {
                    self.drop("Can't reach rigctld at \(self.host):\(self.port) (\(Self.reason(error))). Is it running?")
                } else if done {
                    self.drop("rigctld closed the connection.")
                } else {
                    self.receive(on: c)
                }
            }
        }
    }

    /// "Connection refused" rather than "The operation couldn't be completed. (Network.NWError error 61 …)".
    private static func reason(_ e: NWError) -> String {
        if case .posix(let code) = e { return String(cString: strerror(code.rawValue)) }
        return e.localizedDescription
    }

    private func drop(_ why: String) {
        conn?.cancel(); conn = nil
        awaiting = nil
        report?(.failure(CatError(message: why)))
    }
}

/// flrig: XML-RPC over HTTP, `rig.get_vfo`.
@MainActor
final class FlrigPoller: FrequencyPoller {
    private let url: URL?
    private var timer: Timer?
    private var inFlight = false
    private var report: ((Result<Int, CatError>) -> Void)?
    private static let body = Data(#"<?xml version="1.0"?><methodCall><methodName>rig.get_vfo</methodName></methodCall>"#.utf8)

    init(host: String, port: UInt16) { url = URL(string: "http://\(host):\(port)/RPC2") }

    func start(_ report: @escaping (Result<Int, CatError>) -> Void) {
        self.report = report
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() { timer?.invalidate(); timer = nil; report = nil }

    private func tick() {
        guard !inFlight, let url else { return }
        inFlight = true
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "POST"
        req.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.body
        Task { [weak self] in
            let result: Result<Int, CatError>
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let xml = String(decoding: data, as: UTF8.self)
                result = CatBand.parseFlrig(xml).map { .success($0) }
                    ?? .failure(CatError(message: "flrig gave no frequency. Is a radio connected in flrig?"))
            } catch {
                result = .failure(CatError(message: "Can't reach flrig at \(url.host ?? ""):\(url.port ?? 0) (\(error.localizedDescription))."))
            }
            guard let self else { return }
            self.inFlight = false
            self.report?(result)
        }
    }
}

/// Follows each radio's frequency over CAT and keeps the port's band on the device in step.
@MainActor
final class CatManager: ObservableObject {
    @Published private(set) var status: [Int: CatStatus] = [:]
    @Published private(set) var configs: [Int: CatConfig] = [:]
    private var pollers: [Int: FrequencyPoller] = [:]
    private var lastSent: [Int: (band: Int, at: Date)] = [:]
    private weak var client: AGClient?

    func attach(_ c: AGClient) {
        client = c
        reload()
    }

    func isActive(port id: Int) -> Bool { (configs[id]?.kind ?? .off) != .off }

    /// Re-reads the settings and restarts any link whose settings changed.
    func reload() {
        for id in 1...2 {
            let c = CatConfig.load(port: id)
            guard c != configs[id] || (c.kind != .off && pollers[id] == nil) else { continue }
            pollers[id]?.stop(); pollers[id] = nil
            configs[id] = c
            status[id] = nil
            lastSent[id] = nil
            let poller: FrequencyPoller?
            switch c.kind {
            case .off: poller = nil
            case .rigctld: poller = RigctldPoller(host: c.host, port: c.port)
            case .flrig: poller = FlrigPoller(host: c.host, port: c.port)
            }
            guard let poller else { continue }
            pollers[id] = poller
            poller.start { [weak self] r in self?.received(port: id, r) }
        }
    }

    private func received(port id: Int, _ r: Result<Int, CatError>) {
        var s = status[id] ?? CatStatus()
        switch r {
        case .failure(let e):
            s.error = e.message; s.hz = nil; s.band = nil; s.heldForTX = false
        case .success(let hz):
            s.error = nil; s.hz = hz
            if let client, client.state == .connected, !client.bands.isEmpty,
               let p = client.ports.first(where: { $0.id == id }) {
                let target = CatBand.band(forHz: hz, in: client.bands)
                s.band = target
                s.heldForTX = p.tx && p.band != target
                if let b = CatBand.bandToSend(target: target, port: p) {
                    // Wait for the device to report the last change before repeating it.
                    let recent = lastSent[id].map { $0.band == b && Date().timeIntervalSince($0.at) < 2 } ?? false
                    if !recent {
                        lastSent[id] = (b, Date())
                        client.withOrigin("CAT") { client.setBandFromCAT(port: id, band: b) }
                    }
                }
            }
        }
        if status[id] != s { status[id] = s }
    }
}
