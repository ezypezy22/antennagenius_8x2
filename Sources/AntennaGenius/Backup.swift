import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A device's configuration saved to a JSON file. Network and stacking settings are left out on purpose:
/// restoring them could reboot the unit onto another address or pair it with a unit that isn't there.
struct DeviceBackup: Codable, Equatable {
    var format = 1
    var appVersion = ""
    var created = Date()
    var serial = ""
    var firmware = ""
    var name = ""
    var inbandPort = 0
    var antennas: [AntennaInfo] = []
    var bands: [BandInfo] = []
    var groups: [OutputGroup] = []
    var outputs: [OutputDef] = []
    /// Keyed by port number ("1", "2"), since JSON object keys must be strings.
    var flex: [String: FlexPortConfig] = [:]

    /// The file may have been edited by hand, so anything that reaches the device unfiltered by `wire` is checked.
    /// Returns a reason to refuse it, or nil.
    func problem() -> String? {
        guard format == 1 else { return "This backup was made by a newer version of the app (format \(format))." }
        for b in bands where b.id != 0 {
            guard let lo = Double(b.freqStart), let hi = Double(b.freqStop), lo >= 0, hi >= lo else {
                return "Band \(b.id) has an invalid frequency range."
            }
        }
        for g in groups where !["ANT", "BAND"].contains(g.mode) { return "Output group \(g.id) has an unknown mode “\(g.mode)”." }
        for (port, f) in flex {
            guard Int(port) != nil, NetworkConfig.isSafeToken(f.serial), !f.serial.contains("="),
                  ["ANT1", "ANT2", "XVRT"].contains(f.ant), ["LAN", "RCA"].contains(f.ptt) else {
                return "The FlexRadio settings for port \(port) are invalid."
            }
        }
        return nil
    }
}

extension AGClient {
    func makeBackup() -> DeviceBackup {
        var b = DeviceBackup()
        b.appVersion = AppInfo.version
        b.serial = connectedDevice?.serial ?? ""
        b.firmware = firmware
        b.name = deviceName
        b.inbandPort = inbandPort
        b.antennas = antennas
        b.bands = bands
        b.groups = groups
        b.outputs = outputs
        b.flex = Dictionary(uniqueKeysWithValues: flexConfigs.map { (String($0.key), $0.value) })
        return b
    }

    /// Sends only what differs from the device, and only for antennas, bands and ports it has.
    /// Groups go before outputs, because an output names its group.
    func restore(_ b: DeviceBackup) {
        if !b.name.trimmingCharacters(in: .whitespaces).isEmpty, b.name != deviceName { saveName(b.name) }
        if b.inbandPort != inbandPort { setInbandPort(b.inbandPort) }
        for var x in b.bands where x.id != 0 {
            guard let cur = bands.first(where: { $0.id == x.id }), cur != x else { continue }
            x.freqStart = String(format: "%.6f", Double(x.freqStart) ?? 0)
            x.freqStop = String(format: "%.6f", Double(x.freqStop) ?? 0)
            saveBand(x)
        }
        for x in b.antennas {
            guard let cur = antennas.first(where: { $0.id == x.id }), cur != x else { continue }
            saveAntenna(x)
        }
        for x in b.groups where groups.first(where: { $0.id == x.id }).map({ $0 != x }) ?? x.inUse { saveGroup(x) }
        for x in b.outputs where outputs.first(where: { $0.id == x.id }).map({ $0 != x }) ?? x.inUse { saveOutput(x) }
        for (key, cfg) in b.flex {
            guard let port = Int(key), ports.contains(where: { $0.id == port }), flexConfigs[port] != cfg else { continue }
            saveFlex(port: port, cfg)
        }
    }
}

/// Save and open panels for backup files.
@MainActor
enum BackupFile {
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func encode(_ b: DeviceBackup) throws -> Data { try encoder().encode(b) }

    static func decode(_ data: Data) throws -> DeviceBackup {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(DeviceBackup.self, from: data)
    }

    static func save(_ b: DeviceBackup) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let day = Date().formatted(.iso8601.year().month().day())
        let name = b.name.isEmpty ? "Antenna Genius" : b.name
        panel.nameFieldStringValue = "\(name) \(day).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try encode(b).write(to: url, options: .atomic) }
        catch { alert("Couldn't save the backup", error.localizedDescription) }
    }

    /// Returns the chosen backup, or nil if cancelled or unreadable (after saying why).
    static func open() -> DeviceBackup? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let b = try decode(Data(contentsOf: url))
            if let why = b.problem() { alert("Can't restore this backup", why); return nil }
            return b
        } catch {
            alert("Can't read this backup", "It isn't an Antenna Genius backup file, or it is damaged.")
            return nil
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
