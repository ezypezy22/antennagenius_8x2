import Foundation

/// Parsed `R<seq>|<hex>|<message>` reply.
struct AGResponse {
    let seq: Int
    let code: UInt32
    let message: String
    var ok: Bool { code == 0 }
}

enum AGMessage {
    case prologue(version: String, auth: Bool)
    case response(AGResponse)
    case status(String)
    case unknown(String)
}

enum AGProtocol {
    static let port: UInt16 = 9007

    static func parse(line: String) -> AGMessage {
        guard let first = line.first else { return .unknown(line) }
        switch first {
        case "V":
            let parts = line.split(separator: " ")
            let version = parts.first.map { String($0.dropFirst()) } ?? ""
            return .prologue(version: version, auth: parts.contains("AUTH"))
        case "R":
            let parts = line.dropFirst().split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let seq = Int(parts[0]),
                  let code = UInt32(parts[1], radix: 16) else { return .unknown(line) }
            return .response(AGResponse(seq: seq, code: code, message: parts.count > 2 ? String(parts[2]) : ""))
        case "S":
            let parts = line.dropFirst().split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            return .status(parts.count > 1 ? String(parts[1]) : "")
        default:
            return .unknown(line)
        }
    }

    /// Splits "port 1 auto=1 name=x" into (["port","1"], ["auto":"1","name":"x"]).
    static func tokens(_ message: String) -> (words: [String], kv: [String: String]) {
        var words: [String] = []
        var kv: [String: String] = [:]
        for t in message.split(separator: " ") {
            if let eq = t.firstIndex(of: "=") {
                kv[String(t[..<eq])] = String(t[t.index(after: eq)...])
            } else {
                words.append(String(t))
            }
        }
        return (words, kv)
    }
}

/// UDP discovery beacon: `AG ip=… port=… v=… serial=… name=… ports=2 antennas=8 mode=master uptime=…`
struct DiscoveredDevice: Identifiable, Hashable {
    var id: String { serial }
    let ip: String
    let port: UInt16
    let version: String
    let serial: String
    let name: String
    let ports: Int
    let antennas: Int
    let mode: String

    /// `sourceIP` is the address the packet really came from; it wins over the `ip=` the packet claims,
    /// so a stray or spoofed broadcast can't point the app at some other host.
    init?(beacon: String, sourceIP: String? = nil) {
        guard beacon.hasPrefix("AG") else { return nil }
        let kv = AGProtocol.tokens(beacon).kv
        guard let ip = kv["ip"], let serial = kv["serial"] else { return nil }
        self.ip = sourceIP ?? ip
        self.serial = serial
        self.port = kv["port"].flatMap(UInt16.init) ?? AGProtocol.port
        self.version = kv["v"] ?? ""
        self.name = (kv["name"] ?? "Antenna Genius").replacingOccurrences(of: "_", with: " ")
        self.ports = kv["ports"].flatMap(Int.init) ?? 2
        self.antennas = kv["antennas"].flatMap(Int.init) ?? 8
        self.mode = kv["mode"] ?? ""
    }
}

struct PortState: Equatable {
    var id: Int
    var auto = false
    var source = ""
    var band = 0
    var rxant = 0
    var txant = 0
    var tx = false
    var inhibit = false

    mutating func apply(_ kv: [String: String]) {
        if let v = kv["auto"] { auto = v == "1" }
        if let v = kv["source"] { source = v }
        if let v = kv["band"], let i = Int(v) { band = i }
        if let v = kv["rxant"], let i = Int(v) { rxant = i }
        if let v = kv["txant"], let i = Int(v) { txant = i }
        if let v = kv["tx"] { tx = v != "0" }
        if let v = kv["inhibit"] { inhibit = v != "0" }
    }
}

struct AntennaInfo: Identifiable, Equatable {
    let id: Int
    var name: String
    var tx: Int      // band masks, bit n = band n
    var rx: Int
    var inband: Int
}

struct BandInfo: Identifiable, Equatable {
    let id: Int
    var name: String
    var freqStart = "0.000000"
    var freqStop = "0.000000"
}

struct NetworkConfig: Equatable {
    var dhcp = true
    var address = ""
    var netmask = ""
    var gateway = ""
    var auth = ""

    init() {}
    init(kv: [String: String]) {
        dhcp = kv["dhcp"] != "0"
        address = kv["address"] ?? ""
        netmask = kv["netmask"] ?? ""
        gateway = kv["gateway"] ?? ""
        auth = kv["auth"] ?? ""
    }

    /// True if the text can be sent as one command token: no whitespace, control characters or `|`.
    static func isSafeToken(_ s: String) -> Bool {
        !s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || $0 == "|" }
    }

    static func validIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

struct StackConfig: Equatable {
    var inUse = false
    var serial = ""
    var mode = 0        // 0 = external A/B switches, 1 = using ports 7 & 8

    init() {}
    init(kv: [String: String]) {
        inUse = kv["in_use"] == "1"
        serial = kv["serial"] ?? ""
        mode = Int(kv["mode"] ?? "0") ?? 0
    }
}

/// Another Antenna Genius on the LAN that can be paired for stacking.
struct StackPeer: Identifiable, Equatable {
    var id: String { serial }
    let serial: String
    let name: String
    let antennas: Int
    let ports: Int
}

/// An output group: its outputs follow either the selected antenna (ANT) or the selected band (BAND).
struct OutputGroup: Identifiable, Equatable {
    let id: Int
    var inUse = false
    var name = ""
    var mode = "ANT"
    var antenna = 0
    var bands = 0
    var allowNone = false

    init(id: Int) { self.id = id }
    init?(line: String) {
        let (w, kv) = AGProtocol.tokens(line)
        guard w.count >= 2, w[0] == "group", let id = Int(w[1]) else { return nil }
        self.id = id
        inUse = kv["in_use"] == "1"
        name = (kv["name"] ?? "").replacingOccurrences(of: "_", with: " ")
        mode = (kv["mode"] ?? "ANT").uppercased()
        antenna = Int(kv["antenna"] ?? "0") ?? 0
        bands = Int(kv["bands"] ?? "0", radix: 16) ?? 0
        allowNone = kv["allow_none"] == "1"
    }
}

/// A relay output: `state` is the bitmask of the 8 relays switched on when it is active.
struct OutputDef: Identifiable, Equatable {
    let id: Int
    var inUse = false
    var group = 0
    var name = ""
    var state = 0
    var hotkey = 0
    var trx = false

    init(id: Int) { self.id = id }
    init?(line: String) {
        let (w, kv) = AGProtocol.tokens(line)
        guard w.count >= 2, w[0] == "output", let id = Int(w[1]) else { return nil }
        self.id = id
        inUse = kv["in_use"] == "1"
        group = Int(kv["group"] ?? "0") ?? 0
        name = (kv["name"] ?? "").replacingOccurrences(of: "_", with: " ")
        state = Int(kv["state"] ?? "0", radix: 16) ?? 0
        hotkey = Int(kv["hotkey"] ?? "0") ?? 0
        trx = kv["trx"] == "1"
    }
}

/// Per-port FlexRadio integration: which radio the port is bound to, which antenna jack it uses and where PTT comes from.
struct FlexPortConfig: Equatable {
    var serial = ""
    var ant = "ANT1"     // ANT1, ANT2 or XVRT
    var ptt = "LAN"      // LAN or RCA

    init() {}
    init(kv: [String: String]) {
        serial = kv["serial"] ?? ""
        ant = kv["ant"] ?? "ANT1"
        ptt = kv["ptt"] ?? "LAN"
    }
}

/// A FlexRadio found on the LAN by the Antenna Genius.
struct FlexRadio: Identifiable, Equatable {
    var id: String { serial }
    let model: String
    let serial: String
    let nickname: String
    let callsign: String
}
