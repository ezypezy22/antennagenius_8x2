import Foundation

/// Listens for the Antenna Genius 1 Hz UDP broadcast beacon on port 9007.
@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var devices: [DiscoveredDevice] = []
    /// Set if we can't listen for beacons (e.g. another app already owns UDP 9007).
    @Published private(set) var error: String?
    private var lastSeen: [String: Date] = [:]
    private var source: DispatchSourceRead?
    private var pruneTimer: Timer?
    private var retryTimer: Timer?

    /// Binds UDP 9007. If that fails (port busy), keeps retrying every few seconds until it works.
    func start() {
        guard source == nil else { return }
        if tryBind() { return }
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tryBind() else { return }
                self.retryTimer?.invalidate(); self.retryTimer = nil
            }
        }
    }

    /// One bind attempt. Returns true once listening; sets `error` otherwise.
    private func tryBind() -> Bool {
        // A plain socket, because NWListener only sets SO_REUSEADDR and other apps (e.g. AetherSDR) share the port with SO_REUSEPORT.
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { error = "Can't listen on UDP \(AGProtocol.port) (socket failed)."; return false }
        var on: Int32 = 1
        let optLen = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, optLen) == 0,
              setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, optLen) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            error = "Can't share UDP \(AGProtocol.port) (\(msg))."
            return false
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = AGProtocol.port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            error = "Can't listen on UDP \(AGProtocol.port) (\(msg)). Another app may be using it."
            return false
        }
        error = nil
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readPending(fd) }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        return true
    }

    func stop() {
        source?.cancel(); source = nil
        pruneTimer?.invalidate(); pruneTimer = nil
        retryTimer?.invalidate(); retryTimer = nil
    }

    private func readPending(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) else { return }
        var ip = from.sin_addr
        var name = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &ip, &name, socklen_t(INET_ADDRSTRLEN))
        let src = String(cString: name)
        handle(beacon: text.trimmingCharacters(in: .whitespacesAndNewlines), source: NetworkConfig.validIPv4(src) ? src : nil)
    }

    private func handle(beacon: String, source: String?) {
        guard let d = DiscoveredDevice(beacon: beacon, sourceIP: source) else { return }
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
