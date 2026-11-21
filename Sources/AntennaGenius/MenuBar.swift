import SwiftUI
import AppKit

/// One radio a shortcut or menu item acts on. Which radios are offered follows the port chooser.
struct RadioTarget {
    let port: Int
    let modifiers: EventModifiers
    var letter: String { port == 1 ? "A" : "B" }

    /// SO2R: ⌘ is Radio A and ⇧⌘ is Radio B. Port A or B alone: ⌘ is the radio on screen.
    static func all(_ mode: PortMode) -> [RadioTarget] {
        switch mode {
        case .so2r: return [RadioTarget(port: 1, modifiers: .command), RadioTarget(port: 2, modifiers: [.command, .shift])]
        case .a: return [RadioTarget(port: 1, modifiers: .command)]
        case .b: return [RadioTarget(port: 2, modifiers: .command)]
        }
    }
}

extension AGClient {
    func port(_ id: Int) -> PortState? { ports.first { $0.id == id } }

    func bandName(port id: Int) -> String {
        guard let p = port(id), p.band != 0 else { return "None" }
        return bands.first { $0.id == p.band }?.name ?? "band \(p.band)"
    }

    /// Checked in a menu: this radio receives or transmits on the antenna.
    func isOn(port id: Int, antenna: Int) -> Bool {
        guard let p = port(id) else { return false }
        return p.rxant == antenna || p.txant == antenna
    }
}

// MARK: - Antenna menu (keyboard shortcuts)

/// ⌘1–⌘8 route a radio to an antenna and ⌘0 releases it. Command-modified so typing in Settings can't switch antennas.
struct AntennaCommands: Commands {
    @ObservedObject var client: AGClient
    @AppStorage("portMode") private var portMode = PortMode.so2r.rawValue

    var body: some Commands {
        CommandMenu("Antenna") {
            let connected = client.state == .connected
            ForEach(RadioTarget.all(PortMode(rawValue: portMode) ?? .so2r), id: \.port) { t in
                Text("Radio \(t.letter)")
                ForEach(client.antennas) { a in
                    let item = Toggle(a.name, isOn: Binding(
                        get: { client.isOn(port: t.port, antenna: a.id) },
                        set: { _ in client.selectAntenna(port: t.port, antenna: a.id) }))
                    if a.id <= 9 {
                        item.keyboardShortcut(KeyEquivalent(Character(String(a.id))), modifiers: t.modifiers)
                    } else {
                        item
                    }
                }
                .disabled(!connected)
                Button("Release Radio \(t.letter)") { client.clearAntenna(port: t.port) }
                    .keyboardShortcut("0", modifiers: t.modifiers)
                    .disabled(!connected)
                Divider()
            }
        }
    }
}

// MARK: - Menu bar

/// Antenna switching from the menu bar, without bringing the panel forward.
struct MenuBarContent: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject private var presets = PresetStore.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("portMode") private var portMode = PortMode.so2r.rawValue

    var body: some View {
        if client.state == .connected {
            ForEach(RadioTarget.all(PortMode(rawValue: portMode) ?? .so2r), id: \.port) { t in
                Text("Radio \(t.letter) · \(client.bandName(port: t.port))")
                ForEach(client.antennas) { a in
                    Toggle(a.name, isOn: Binding(
                        get: { client.isOn(port: t.port, antenna: a.id) },
                        set: { on in
                            if on { client.selectAntenna(port: t.port, antenna: a.id) } else { client.clearAntenna(port: t.port) }
                        }))
                }
                Divider()
            }
            if !presets.presets.isEmpty {
                Menu("Presets") { PresetMenuItems(client: client) }
                Divider()
            }
            if let err = client.lastError {
                Text("⚠︎ \(err)")
                Button("Dismiss message") { client.lastError = nil }
                Divider()
            }
        } else {
            Text(statusText)
            Divider()
        }
        Button("Show Antenna Genius") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit Antenna Genius") { AppDelegate.quit() }
    }

    private var statusText: String {
        switch client.state {
        case .connecting: return "Connecting…"
        case .failed: return client.autoConnect && client.lastDevice != nil ? "Trying to reconnect…" : "Not connected"
        default: return "Not connected"
        }
    }
}

/// The menu bar shows each visible radio's antenna, e.g. "A Yagi · B Dipole".
struct MenuBarLabel: View {
    @EnvironmentObject var client: AGClient
    @AppStorage("portMode") private var portMode = PortMode.so2r.rawValue

    var body: some View {
        Label(text, systemImage: "antenna.radiowaves.left.and.right")
            .labelStyle(.titleAndIcon)
    }

    private var text: String {
        guard client.state == .connected else { return "" }
        return RadioTarget.all(PortMode(rawValue: portMode) ?? .so2r).map { t in
            "\(t.letter) \(short(antennaName(t.port)))"
        }.joined(separator: " · ")
    }

    private func antennaName(_ port: Int) -> String {
        guard let p = client.port(port) else { return "—" }
        let id = p.txant != 0 ? p.txant : p.rxant
        return client.antennas.first { $0.id == id }?.name ?? "—"
    }

    private func short(_ s: String) -> String { s.count > 12 ? String(s.prefix(11)) + "…" : s }
}
