import Foundation
import Network

enum ConnectionState: Equatable {
    case disconnected, connecting, connected
    case failed(String)
}

/// The protocol log shown in the log window.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    func append(_ s: String) {
        lines.append(s)
        if lines.count > 1000 { lines.removeFirst(lines.count - 1000) }
    }
}

/// TCP client for one Antenna Genius. All callbacks run on the main queue.
@MainActor
final class AGClient: ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var firmware = ""
    @Published private(set) var ports: [PortState] = []
    @Published private(set) var antennas: [AntennaInfo] = []
    @Published private(set) var bands: [BandInfo] = []
    /// Separate object so a new log line only redraws the log window, not every view watching the client.
    let logStore = LogStore()
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
    /// The device we were last connected to; used to reconnect after a reboot or network change.
    private(set) var lastDevice: DiscoveredDevice?
    private var followSource: [Int: String] = [:]   // last non-MANUAL source per port

    private var conn: NWConnection?
    private var buffer = Data()
    private var seq = 0
    private var pending: [Int: (AGResponse) -> Void] = [:]
    private var listAccumulator: [Int: [String]] = [:]
    private var pingTimer: Timer?
    private var portCount = 2
    private var quiet: Set<Int> = []          // sequence numbers whose OK replies are not logged (pings)
    private var waitTimer: Timer?
    private var isWaiting = false
    private var waitingReason = ""

    func connect(to device: DiscoveredDevice) {
        disconnect()
        state = .connecting
        lastDevice = device
        connectedDevice = device
        lastError = nil
        portCount = max(device.ports, 1)
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

    /// Called regularly by the connect screen. After the unit reboots (or its address changes) it finds the
    /// same unit again by serial number and reconnects, unless the user disconnected on purpose.
    func autoReconnect(discovered: [DiscoveredDevice]) {
        guard autoConnect else { return }
        switch state {
        case .disconnected, .failed: break
        default: return
        }
        if let last = lastDevice {
            if let d = discovered.first(where: { $0.serial == last.serial }) { connect(to: d) }
            else if last.serial.hasPrefix("manual-") { connect(to: last) }   // typed IP: not in the broadcast list
        } else if discovered.count == 1, let d = discovered.first {
            connect(to: d)
        }
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        stopWaiting()
        conn?.cancel(); conn = nil
        buffer.removeAll(); pending.removeAll(); listAccumulator.removeAll(); quiet.removeAll()
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

    /// Free text becomes one command token: control characters are dropped and spaces, `|` and `=` become `_`,
    /// so a name can never end a command early or smuggle in another one.
    func wire(_ name: String) -> String {
        let kept = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var s = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        for bad in [" ", "|", "="] { s = s.replacingOccurrences(of: bad, with: "_") }
        return s
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

    /// Changing DHCP, or any address while DHCP is off, makes the device reboot (~20 s offline).
    func saveNetwork(_ n: NetworkConfig) {
        guard NetworkConfig.isSafeToken(n.auth) else {
            lastError = "The remote access password can't contain spaces or control characters."
            return
        }
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
            stopWaiting()
            if state != .connected { state = .connected; bootstrap() }
        case .failed(let e):
            fail(e.localizedDescription)
        case .waiting(let e):
            // macOS reports .waiting while it is still trying (e.g. while the Local Network permission
            // prompt is open), so give it time instead of failing straight away.
            waitingReason = e.localizedDescription
            if !isWaiting {
                isWaiting = true
                waitTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.isWaiting else { return }
                        self.fail("Can't reach the device (\(self.waitingReason)). If macOS asked for Local Network access, allow it and try again.")
                    }
                }
            }
        case .cancelled:
            break
        default:
            break
        }
    }

    private func stopWaiting() {
        waitTimer?.invalidate(); waitTimer = nil
        isWaiting = false
    }

    private func fail(_ reason: String) {
        stopWaiting()
        pingTimer?.invalidate(); pingTimer = nil
        conn?.cancel(); conn = nil
        state = .failed(reason)
    }

    private func bootstrap() {
        send("keepalive enable")
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send("ping", quiet: true) }
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
        for p in 1...max(portCount, 1) { refreshPort(p) }
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

    private func send(_ cmd: String, quiet isQuiet: Bool = false, reply: ((AGResponse) -> Void)? = nil) {
        let s = nextSeq()
        if isQuiet { quiet.insert(s) } else { quiet.remove(s) }
        pending[s] = { [weak self] r in
            if !r.ok { self?.lastError = "“\(Self.masked(cmd))” rejected by device (0x\(String(r.code, radix: 16)))" }
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
        let parsed = AGProtocol.parse(line: line)
        var skipLog = false
        if case .response(let r) = parsed, quiet.remove(r.seq) != nil, r.ok { skipLog = true }
        if !skipLog { appendLog("← \(line)") }
        switch parsed {
        case .prologue(let v, _):
            firmware = v
        case .response(let r):
            if listAccumulator[r.seq] != nil {
                if r.message.isEmpty || !r.ok {
                    let rows = listAccumulator.removeValue(forKey: r.seq) ?? []
                    pending[r.seq] = nil
                    let done = listDone.removeValue(forKey: r.seq)
                    if r.ok { done?(rows) }   // on error keep the data we already have
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

    /// Hides the remote access password anywhere a command or reply is shown.
    static func masked(_ s: String) -> String {
        s.replacingOccurrences(of: #"auth=\S+"#, with: "auth=***", options: .regularExpression)
    }

    private func appendLog(_ s: String) { logStore.append(Self.masked(s)) }
}
