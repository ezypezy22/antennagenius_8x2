import Foundation
import Network

/// Listens for the Antenna Genius 1 Hz UDP broadcast beacon on port 9007.
@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var devices: [DiscoveredDevice] = []
    /// Set if we can't listen for beacons (e.g. another app already owns UDP 9007).
    @Published private(set) var error: String?
    private var lastSeen: [String: Date] = [:]
    private var listener: NWListener?
    private var pruneTimer: Timer?

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: AGProtocol.port)!) else {
            error = "Can't listen on UDP 9007. Another app may be using it."
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Self.receive(on: conn, owner: self)
        }
        l.stateUpdateHandler = { [weak self] st in
            MainActor.assumeIsolated {
                switch st {
                case .failed(let e), .waiting(let e):
                    self?.error = "Can't listen on UDP 9007 (\(e.localizedDescription)). Another app may be using it."
                case .ready: self?.error = nil
                default: break
                }
            }
        }
        l.start(queue: .main)
        listener = l
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        pruneTimer?.invalidate(); pruneTimer = nil
    }

    private nonisolated static func receive(on conn: NWConnection, owner: Discovery?) {
        conn.receiveMessage { data, _, _, error in
            if let data, let text = String(data: data, encoding: .utf8) {
                MainActor.assumeIsolated { owner?.handle(beacon: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            if error == nil { receive(on: conn, owner: owner) } else { conn.cancel() }
        }
    }

    private func handle(beacon: String) {
        guard let d = DiscoveredDevice(beacon: beacon) else { return }
        lastSeen[d.id] = Date()
        if let i = devices.firstIndex(where: { $0.id == d.id }) {
            if devices[i] != d { devices[i] = d }
        } else {
            devices.append(d)
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-6)
        devices.removeAll { (lastSeen[$0.id] ?? .distantPast) < cutoff }
    }
}
