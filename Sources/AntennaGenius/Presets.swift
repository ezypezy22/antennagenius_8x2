import AppKit
import SwiftUI

// MARK: - Antenna presets: named setups of both radios' antennas (and optionally output relays)

struct AntennaPreset: Codable, Identifiable, Equatable {
    struct Radio: Codable, Equatable {
        var port: Int
        var rx: Int   // 0 = none
        var tx: Int
    }
    var id = UUID()
    var name: String
    /// Ports not listed are left as they are.
    var radios: [Radio]
    /// Outputs switched on after the antennas (manual relay outputs).
    var outputs: [Int] = []

    /// Link that applies this preset, for Stream Deck, Shortcuts ("Open URLs") or scripts.
    var url: URL {
        var c = URLComponents()
        c.scheme = Automation.scheme
        c.host = "preset"
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        return c.url!
    }
}

@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    @Published var presets: [AntennaPreset] = [] { didSet { persist() } }
    private var loading = false

    init() {
        loading = true
        if let data = UserDefaults.standard.data(forKey: "presets"),
           let list = try? JSONDecoder().decode([AntennaPreset].self, from: data) { presets = list }
        loading = false
    }

    private func persist() {
        guard !loading, let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: "presets")
    }

    /// Case-insensitive, ignoring spaces and underscores, as names arrive from URLs.
    static func key(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && $0 != "_" }
    }

    func preset(named name: String) -> AntennaPreset? {
        presets.first { Self.key($0.name) == Self.key(name) }
    }

    /// A name no other preset has (links find presets by name).
    func uniqueName(_ wanted: String, except id: UUID? = nil) -> String {
        let base = wanted.trimmingCharacters(in: .whitespaces).isEmpty ? "Preset" : wanted.trimmingCharacters(in: .whitespaces)
        var name = base, n = 2
        while presets.contains(where: { $0.id != id && Self.key($0.name) == Self.key(name) }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// The radios shown in the current port view, as they are now.
    func capture(from client: AGClient, mode: PortMode, name: String) -> AntennaPreset {
        let radios = client.ports.filter { mode.shows($0.id) }.map { AntennaPreset.Radio(port: $0.id, rx: $0.rxant, tx: $0.txant) }
        return AntennaPreset(name: uniqueName(name), radios: radios)
    }

    /// Asks for a name, then saves the current setup as a new preset.
    func saveCurrent(from client: AGClient) {
        guard client.state == .connected else { return }
        let a = NSAlert()
        a.messageText = "Save current setup as a preset"
        a.informativeText = "Saves each shown radio's RX and TX antenna. Output relays can be added in Manage Presets."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name, e.g. Contest 20/40"
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let mode = PortMode(rawValue: UserDefaults.standard.string(forKey: "portMode") ?? "") ?? .so2r
        presets.append(capture(from: client, mode: mode, name: field.stringValue))
    }

    func apply(_ p: AntennaPreset, to client: AGClient) {
        client.apply(preset: p)
    }

    /// "A Yagi · B RX Beverage, TX Vertical"
    static func summary(_ p: AntennaPreset, antennas: [AntennaInfo], outputs: [OutputDef]) -> String {
        func name(_ id: Int) -> String { id == 0 ? "none" : antennas.first { $0.id == id }?.name ?? "Antenna \(id)" }
        var parts = p.radios.sorted { $0.port < $1.port }.map { r -> String in
            let letter = r.port == 1 ? "A" : "B"
            return r.rx == r.tx ? "\(letter) \(name(r.rx))" : "\(letter) RX \(name(r.rx)), TX \(name(r.tx))"
        }
        if !p.outputs.isEmpty {
            parts.append("outputs " + p.outputs.map { id in outputs.first { $0.id == id }?.name ?? "\(id)" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

extension AGClient {
    /// Sets each listed radio's antennas, then switches on the preset's outputs. A radio that is transmitting
    /// is left alone: switching antennas under power can damage the switch or an amplifier.
    func apply(preset p: AntennaPreset) {
        guard state == .connected else { lastError = "Not connected, so “\(p.name)” wasn't applied."; return }
        var skipped: [String] = []
        for r in p.radios {
            guard let port = ports.first(where: { $0.id == r.port }) else { continue }
            if port.tx { skipped.append(r.port == 1 ? "A" : "B"); continue }
            setAntennas(port: r.port, rx: r.rx, tx: r.tx)
        }
        for o in p.outputs { activateOutput(o) }
        if !skipped.isEmpty {
            lastError = "“\(p.name)”: Radio \(skipped.joined(separator: " and ")) was transmitting, so it wasn't switched."
        }
    }
}

// MARK: - Menus

/// Preset items for the Presets menu, the gear menu and the menu bar. ⌥⌘1–⌥⌘9 apply the first nine.
struct PresetMenuItems: View {
    @ObservedObject var store = PresetStore.shared
    @ObservedObject var client: AGClient
    var shortcuts = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(store.presets.enumerated()), id: \.element.id) { i, p in
            let item = Button(p.name) { store.apply(p, to: client) }.disabled(client.state != .connected)
            if shortcuts && i < 9 {
                item.keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .option])
            } else {
                item
            }
        }
        if !store.presets.isEmpty { Divider() }
        Button("Save Current Setup as Preset…") { store.saveCurrent(from: client) }.disabled(client.state != .connected)
        Button("Manage Presets…") { openWindow(id: "presets"); NSApp.activate() }
    }
}

struct PresetCommands: Commands {
    @ObservedObject var client: AGClient
    var body: some Commands {
        CommandMenu("Presets") { PresetMenuItems(client: client, shortcuts: true) }
    }
}

// MARK: - Manage window

struct PresetsWindowRoot: View {
    @AppStorage("appearance") private var appearance = Appearance.light.rawValue
    var body: some View {
        let _ = Appearance.apply(appearance)
        PresetsView()
            .background(Theme.window)
            .preferredColorScheme(appearance == Appearance.light.rawValue ? .light : .dark)
            .id(appearance)
    }
}

struct PresetsView: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var store = PresetStore.shared
    @StateObject private var copied = Box<UUID?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.presets.isEmpty {
                Text("No presets yet. Set up the antennas, then choose Save Current Setup as Preset… from the Presets menu.")
                    .foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($store.presets) { $p in row($p) }
                        .onMove { store.presets.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            Divider()
            HStack {
                Text("Drag to reorder: the first nine are ⌥⌘1–⌥⌘9. A preset's link works in Stream Deck (Open / Website action), Shortcuts (Open URLs) or `open` in a script.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Save Current Setup…") { store.saveCurrent(from: client) }.disabled(client.state != .connected)
            }.padding(10)
        }
        .frame(minWidth: 560, minHeight: 300)
    }

    private func row(_ p: Binding<AntennaPreset>) -> some View {
        let preset = p.wrappedValue
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Name", text: Binding(get: { p.wrappedValue.name },
                                                set: { p.wrappedValue.name = store.uniqueName($0, except: preset.id) }))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                Spacer()
                Button("Apply") { store.apply(preset, to: client) }.disabled(client.state != .connected)
                Button(copied.value == preset.id ? "Copied" : "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preset.url.absoluteString, forType: .string)
                    copied.value = preset.id
                }.help(preset.url.absoluteString)
                Menu("Outputs") {
                    ForEach(client.outputs.filter(\.inUse)) { o in
                        Toggle(o.name.isEmpty ? "Output \(o.id)" : o.name, isOn: Binding(
                            get: { p.wrappedValue.outputs.contains(o.id) },
                            set: { on in
                                p.wrappedValue.outputs.removeAll { $0 == o.id }
                                if on { p.wrappedValue.outputs.append(o.id) }
                            }))
                    }
                    if client.outputs.filter(\.inUse).isEmpty { Text("No outputs in use") }
                }.fixedSize()
                Button(role: .destructive) { store.presets.removeAll { $0.id == preset.id } } label: { Image(systemName: "trash") }
                    .help("Delete this preset")
            }
            Text(PresetStore.summary(preset, antennas: client.antennas, outputs: client.outputs))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}
