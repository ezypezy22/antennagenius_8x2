import Foundation
import Network

enum ConnectionState: Equatable {
    case disconnected, connecting, connected
    case failed(String)
}

/// TCP client for one Antenna Genius. All callbacks run on the main queue.
@MainActor
final class AGClient: ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var firmware = ""
    @Published private(set) var ports: [PortState] = []
    @Published private(set) var antennas: [AntennaInfo] = []
    @Published private(set) var bands: [BandInfo] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var connectedDevice: DiscoveredDevice?
    @Published private(set) var deviceName = ""
    @Published private(set) var inbandPort = 0
    @Published private(set) var stack = StackConfig()
    @Published private(set) var flexConfigs: [Int: FlexPortConfig] = [:]
    @Published private(set) var flexRadios: [FlexRadio] = []
    @Published private(set) var groups: [OutputGroup] = []
    @Published private(set) var outputs: [OutputDef] = []
    @Published private(set) var relayState = 0
    @Published private(set) var stackPeers: [StackPeer] = []
    @Published private(set) var network: NetworkConfig?
    @Published var lastError: String?
    /// Cleared when the user disconnects on purpose, so we don't immediately reconnect.
    var autoConnect = true
    private var followSource: [Int: String] = [:]   // last non-MANUAL source per port

    private var conn: NWConnection?
    private var buffer = Data()
    private var seq = 0
    private var pending: [Int: (AGResponse) -> Void] = [:]
    private var listAccumulator: [Int: [String]] = [:]
    private var pingTimer: Timer?
    private var portCount = 2

    func connect(to device: DiscoveredDevice) {
        disconnect()
        state = .connecting
        connectedDevice = device
        lastError = nil
        portCount = device.ports
        ports = (1...max(device.ports, 1)).map { PortState(id: $0) }
        antennas = (1...max(device.antennas, 1)).map { AntennaInfo(id: $0, name: "Antenna \($0)", tx: 0, rx: 0, inband: 0) }

        let c = NWConnection(host: NWEndpoint.Host(device.ip), port: NWEndpoint.Port(rawValue: device.port)!, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated { self?.handle(state: s, conn: c) }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        conn?.cancel(); conn = nil
        buffer.removeAll(); pending.removeAll(); listAccumulator.removeAll()
        if state != .disconnected { state = .disconnected }
        connectedDevice = nil
    }

    // MARK: Commands

    /// The device accepts an RX antenna if its rx mask has the port's band bit set (band 0 = "None"
    /// is RX-enabled by default), and a TX antenna if its tx mask does. Port source must be MANUAL.
    func selectAntenna(port id: Int, antenna: Int, rx: Bool = true, tx: Bool = true) {
        guard let p = ports.first(where: { $0.id == id }),
              let ant = antennas.first(where: { $0.id == antenna }) else { return }
        let bandName = bands.first { $0.id == p.band }?.name ?? "band \(p.band)"
        let rxOK = rx && ant.rx & (1 << p.band) != 0
        let txOK = tx && ant.tx & (1 << p.band) != 0
        if !rxOK && !txOK {
            lastError = "\(ant.name) isn't enabled for \(bandName) on Radio \(id == 1 ? "A" : "B")."
            return
        }
        var cmd = "port set \(id)"
        if p.source != "MANUAL" { cmd += " source=MANUAL" }
        if rxOK { cmd += " rxant=\(antenna)" }
        if txOK { cmd += " txant=\(antenna)" }
        let other = ports.first { $0.id != id && ($0.rxant == antenna || $0.txant == antenna) }
        send(cmd) { [weak self] r in
            if !r.ok, let other {
                self?.lastError = "\(ant.name) is in use by Radio \(other.id == 1 ? "A" : "B"). The device refused to put both radios on it — release Radio \(other.id == 1 ? "A" : "B") first."
            }
            self?.refreshPort(id)
        }
    }

    func clearAntenna(port id: Int) {
        send("port set \(id) rxant=0 txant=0") { [weak self] _ in self?.refreshPort(id) }
    }

    func setAuto(port: Int, _ on: Bool) {
        send("port set \(port) auto=\(on ? 1 : 0)") { [weak self] _ in self?.refreshPort(port) }
    }

    func setBand(port: Int, band: Int) {
        guard let p = ports.first(where: { $0.id == port }) else { return }
        send("port set \(port)\(p.source == "MANUAL" ? "" : " source=MANUAL") band=\(band)") { [weak self] _ in
            self?.refreshPort(port)
        }
    }

    /// Manual on → take control; off → hand the port back to whatever source it followed before.
    func setManual(port: Int, _ on: Bool) {
        let src = on ? "MANUAL" : (followSource[port] ?? "FLEX")
        send("port set \(port) source=\(src)") { [weak self] _ in self?.refreshPort(port) }
    }

    // MARK: Configuration

    private func wire(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
    }

    func saveAntenna(_ a: AntennaInfo) {
        let hex = { (m: Int) in String(format: "%04X", m) }
        send("antenna set \(a.id) name=\(wire(a.name)) tx=\(hex(a.tx)) rx=\(hex(a.rx)) inband=\(hex(a.inband))") { [weak self] r in
            if r.ok { self?.loadAntennas() }
        }
    }

    func saveBand(_ b: BandInfo) {
        send("band set \(b.id) name=\(wire(b.name)) freq_start=\(b.freqStart) freq_stop=\(b.freqStop)") { [weak self] r in
            if r.ok { self?.loadBands() }
        }
    }

    func loadConf() {
        send("conf get") { [weak self] r in
            guard r.ok else { return }
            let kv = AGProtocol.tokens(r.message).kv
            if let n = kv["name"] { self?.deviceName = n.replacingOccurrences(of: "_", with: " ") }
            if let i = kv["inband_port"].flatMap(Int.init) { self?.inbandPort = i }
        }
    }

    func loadNetwork() {
        send("network get") { [weak self] r in
            guard r.ok else { return }
            self?.network = NetworkConfig(kv: AGProtocol.tokens(r.message).kv)
        }
    }

    func saveName(_ name: String) {
        send("conf set name=\(wire(name))") { [weak self] r in
            if r.ok { self?.loadConf() }
        }
    }

    /// Changing DHCP, or any address while DHCP is off, makes the device reboot (~20 s offline).
    func loadStack() {
        send("stack get") { [weak self] r in
            guard r.ok else { return }
            self?.stack = StackConfig(kv: AGProtocol.tokens(r.message).kv)
        }
    }

    func loadStackPeers() {
        sendList("stack list") { [weak self] lines in
            self?.stackPeers = lines.compactMap { line in
                let kv = AGProtocol.tokens(line).kv
                guard let serial = kv["serial"], !serial.isEmpty else { return nil }
                return StackPeer(serial: serial,
                                 name: (kv["name"] ?? "").replacingOccurrences(of: "_", with: " "),
                                 antennas: Int(kv["antennas"] ?? "") ?? 0, ports: Int(kv["ports"] ?? "") ?? 0)
            }
        }
    }

    func saveStack(_ c: StackConfig) {
        var cmd = "stack set \(c.inUse ? 1 : 0)"
        if c.inUse { cmd += " serial=\(c.serial) mode=\(c.mode)" }
        send(cmd) { [weak self] r in
            if r.ok { self?.loadStack(); self?.loadAntennas() }
        }
    }

    // MARK: FlexRadio integration

    func loadFlex() {
        for p in 1...max(portCount, 1) {
            send("flex get \(p)") { [weak self] r in
                guard r.ok else { return }
                self?.flexConfigs[p] = FlexPortConfig(kv: AGProtocol.tokens(r.message).kv)
            }
        }
        sendList("flex list") { [weak self] lines in
            self?.flexRadios = lines.compactMap { line in
                let kv = AGProtocol.tokens(line).kv
                guard let serial = kv["serial"], !serial.isEmpty else { return nil }
                return FlexRadio(model: kv["model"] ?? "", serial: serial,
                                 nickname: kv["nickname"] ?? "", callsign: kv["callsign"] ?? "")
            }
        }
    }

    func saveFlex(port: Int, _ c: FlexPortConfig) {
        send("flex set \(port) serial=\(c.serial) ant=\(c.ant) ptt=\(c.ptt)") { [weak self] r in
            if r.ok { self?.loadFlex() }
        }
    }

    // MARK: Output relays

    func loadOutputs() {
        sendList("group list") { [weak self] lines in
            self?.groups = lines.compactMap(OutputGroup.init(line:)).sorted { $0.id < $1.id }
        }
        sendList("output list") { [weak self] lines in
            self?.outputs = lines.compactMap(OutputDef.init(line:)).sorted { $0.id < $1.id }
        }
    }

    func saveGroup(_ g: OutputGroup) {
        var cmd = "group set \(g.id) in_use=\(g.inUse ? 1 : 0) name=\(wire(g.name)) mode=\(g.mode)"
        cmd += g.mode == "ANT" ? " antenna=\(g.antenna)" : " bands=\(String(format: "%X", g.bands))"
        cmd += " allow_none=\(g.allowNone ? 1 : 0)"
        send(cmd) { [weak self] r in if r.ok { self?.loadOutputs() } }
    }

    func saveOutput(_ o: OutputDef) {
        let cmd = "output set \(o.id) in_use=\(o.inUse ? 1 : 0) group_id=\(o.group) name=\(wire(o.name)) state=\(String(format: "%02X", o.state)) hotkey=\(o.hotkey) trx=\(o.trx ? 1 : 0)"
        send(cmd) { [weak self] r in if r.ok { self?.loadOutputs() } }
    }

    /// Switches the output on, which energises its relays.
    func activateOutput(_ id: Int) { send("output set \(id) active=1") }

    /// The documentation calls this mandatory before configuring groups and outputs.
    func initOutputs() { send("output init") { [weak self] r in if r.ok { self?.loadOutputs() } } }

    func setInbandPort(_ port: Int) {
        send("conf set inband_port=\(port)") { [weak self] r in
            if r.ok { self?.loadConf() }
        }
    }

    /// Device drops all connections and is offline ~20 s.
    func reboot() { send("reboot") }

    /// Restores factory defaults (names, bands, antenna setup, network); the device reboots itself.
    func factoryReset() { send("conf init") }

    func saveNetwork(_ n: NetworkConfig) {
        var cmd = "network set dhcp=\(n.dhcp ? 1 : 0)"
        if !n.dhcp { cmd += " address=\(n.address) netmask=\(n.netmask) gateway=\(n.gateway)" }
        if !n.auth.isEmpty { cmd += " auth=\(n.auth)" }
        send(cmd) { [weak self] r in
            if r.ok { self?.loadNetwork() }
        }
    }

    func refreshPort(_ id: Int) {
        send("port get \(id)") { [weak self] r in
            guard r.ok else { return }
            self?.applyPort(message: r.message)
        }
    }

    // MARK: Plumbing

    private func handle(state s: NWConnection.State, conn c: NWConnection) {
        guard c === conn else { return }
        switch s {
        case .ready:
            state = .connected
            bootstrap()
        case .failed(let e):
            fail(e.localizedDescription)
        case .waiting(let e):
            fail(e.localizedDescription)
        case .cancelled:
            break
        default:
            break
        }
    }

    private func fail(_ reason: String) {
        pingTimer?.invalidate(); pingTimer = nil
        conn?.cancel(); conn = nil
        state = .failed(reason)
    }

    private func bootstrap() {
        send("keepalive enable")
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send("ping") }
        }
        send("sub port all")
        send("sub relay")
        send("sub output")
        loadBands()
        loadAntennas()
        loadConf()
        loadNetwork()
        loadStack()
        loadStackPeers()
        loadOutputs()
        loadFlex()
        for p in 1...portCount { refreshPort(p) }
    }

    func loadAntennas() {
        sendList("antenna list") { [weak self] lines in
            var result: [AntennaInfo] = []
            for line in lines {
                let (w, kv) = AGProtocol.tokens(line)
                guard w.count >= 2, w[0] == "antenna", let id = Int(w[1]) else { continue }
                result.append(AntennaInfo(
                    id: id,
                    name: (kv["name"] ?? "Antenna \(id)").replacingOccurrences(of: "_", with: " "),
                    tx: Int(kv["tx"] ?? "0", radix: 16) ?? 0,
                    rx: Int(kv["rx"] ?? "0", radix: 16) ?? 0,
                    inband: Int(kv["inband"] ?? "0", radix: 16) ?? 0))
            }
            if !result.isEmpty { self?.antennas = result.sorted { $0.id < $1.id } }
        }
    }

    func loadBands() {
        sendList("band list") { [weak self] lines in
            var result: [BandInfo] = []
            for line in lines {
                let (w, kv) = AGProtocol.tokens(line)
                guard w.count >= 2, w[0] == "band", let id = Int(w[1]) else { continue }
                result.append(BandInfo(id: id, name: (kv["name"] ?? "\(id)").replacingOccurrences(of: "_", with: " "),
                                       freqStart: kv["freq_start"] ?? "0.000000", freqStop: kv["freq_stop"] ?? "0.000000"))
            }
            if !result.isEmpty { self?.bands = result.sorted { $0.id < $1.id } }
        }
    }

    /// Sends a command whose reply is a series of `R<seq>|0|<row>` lines terminated by an empty row.
    private func sendList(_ cmd: String, done: @escaping ([String]) -> Void) {
        let s = nextSeq()
        listAccumulator[s] = []
        pending[s] = { _ in }
        write("C\(s)|\(cmd)")
        listDone[s] = done
    }
    private var listDone: [Int: ([String]) -> Void] = [:]

    private func send(_ cmd: String, reply: ((AGResponse) -> Void)? = nil) {
        let s = nextSeq()
        pending[s] = { [weak self] r in
            if !r.ok { self?.lastError = "“\(cmd)” rejected by device (0x\(String(r.code, radix: 16)))" }
            reply?(r)
        }
        write("C\(s)|\(cmd)")
    }

    private func nextSeq() -> Int {
        seq = seq % 255 + 1
        return seq
    }

    private func write(_ line: String) {
        if !line.hasSuffix("|ping") { appendLog("→ \(line)") }
        conn?.send(content: Data((line + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, c === self.conn else { return }
                if let data { self.ingest(data) }
                if isComplete || error != nil {
                    self.fail(error?.localizedDescription ?? "Connection closed by device")
                } else {
                    self.receive(on: c)
                }
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let idx = buffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            dispatch(line)
        }
    }

    private func dispatch(_ line: String) {
        appendLog("← \(line)")
        switch AGProtocol.parse(line: line) {
        case .prologue(let v, _):
            firmware = v
        case .response(let r):
            if listAccumulator[r.seq] != nil {
                if r.message.isEmpty || !r.ok {
                    let rows = listAccumulator.removeValue(forKey: r.seq) ?? []
                    pending[r.seq] = nil
                    listDone.removeValue(forKey: r.seq)?(rows)
                } else {
                    listAccumulator[r.seq]?.append(r.message)
                }
            } else if let cb = pending.removeValue(forKey: r.seq) {
                cb(r)
            }
        case .status(let msg):
            handle(status: msg)
        case .unknown:
            break
        }
    }

    private func handle(status msg: String) {
        let (w, _) = AGProtocol.tokens(msg)
        switch w.first {
        case "port": applyPort(message: msg)
        case "antenna": loadAntennas()
        case "relay":
            if let h = AGProtocol.tokens(msg).kv["state"], let v = Int(h, radix: 16) { relayState = v }
        case "output", "group": loadOutputs()
        default: break
        }
    }

    private func applyPort(message: String) {
        let (w, kv) = AGProtocol.tokens(message)
        guard w.count >= 2, w[0] == "port", let id = Int(w[1]),
              let i = ports.firstIndex(where: { $0.id == id }) else { return }
        ports[i].apply(kv)
        if let src = kv["source"], src != "MANUAL" { followSource[id] = src }
    }

    private func appendLog(_ s: String) {
        let masked = s.replacingOccurrences(of: #"auth=\S+"#, with: "auth=***", options: .regularExpression)
        log.append(masked)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}
