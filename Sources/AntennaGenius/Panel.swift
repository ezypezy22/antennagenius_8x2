import SwiftUI

// MARK: - Main panel

struct PanelView: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var showAbout: Box<Bool>
    @Binding var portMode: String
    let reselect: () -> Void
    private var mode: PortMode { PortMode(rawValue: portMode) ?? .so2r }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(showAbout: showAbout, reselect: reselect)
            if let err = client.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.system(size: Theme.fs(11))).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { client.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(6).background(Color.orange.opacity(0.18))
            }
            Text(client.deviceName.isEmpty ? (client.connectedDevice?.name ?? "Antenna Genius") : client.deviceName)
                .font(.system(size: Theme.fs(15), weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Theme.chrome)
            HStack(spacing: 2) {
                ForEach(client.ports.filter { mode.shows($0.id) }, id: \.id) { SourceBandHeader(port: $0) }
            }
            .padding(.horizontal, 2)
            VStack(spacing: 2) {
                ForEach(client.antennas) { AntennaRow(ant: $0, mode: mode) }
            }
            .padding(.horizontal, 2).padding(.top, 2).padding(.bottom, 2)
            Text("Version \(AppInfo.version)").font(.system(size: Theme.fs(10))).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.bottom, 8)
        }
    }
}

struct PanelButton: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: Theme.fs(12), weight: .semibold)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: Theme.fs(26))
            .background(Theme.button, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.edge, lineWidth: Theme.lineWidth))
    }
}

/// Top of each radio column: source (MANUAL / FLEX…) and band, like the Windows panel.
struct SourceBandHeader: View {
    @EnvironmentObject var client: AGClient
    let port: PortState
    @StateObject private var picking = Box(false)

    private var bandName: String {
        client.bands.first { $0.id == port.band }?.name ?? "None"
    }

    var body: some View {
        VStack(spacing: 2) {
            Button { client.setManual(port: port.id, port.source != "MANUAL") } label: {
                PanelButton(title: port.source.isEmpty ? "—" : port.source)
            }.buttonStyle(.plain)
            Button { picking.value = true } label: { PanelButton(title: bandName) }
                .buttonStyle(.plain)
                .disabled(port.source != "MANUAL")
                .opacity(port.source == "MANUAL" ? 1 : (Theme.scale > 1 ? 0.8 : 0.6))
                .popover(isPresented: $picking.value, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(client.bands) { b in
                                Button {
                                    client.setBand(port: port.id, band: b.id)
                                    picking.value = false
                                } label: {
                                    HStack {
                                        Text(b.id == 0 ? "None" : b.name)
                                        Spacer()
                                        if b.id == port.band { Image(systemName: "checkmark") }
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 5).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 4)
                    }
                    .frame(width: 150, height: min(CGFloat(client.bands.count) * 28 + 8, 360))
                }
        }
    }
}

struct AntennaRow: View {
    @EnvironmentObject var client: AGClient
    let ant: AntennaInfo
    var mode: PortMode = .so2r

    private func port(_ id: Int) -> PortState? { mode.shows(id) ? client.ports.first { $0.id == id } : nil }

    /// Background for one radio's share of the name cell (transmit overrides the radio colour).
    private func fill(_ p: PortState?) -> LinearGradient? {
        guard let p else { return nil }
        if p.tx && p.txant == ant.id { return Theme.transmit }   // red only while actually transmitting
        if p.rxant == ant.id || p.txant == ant.id { return Theme.selected(port: p.id) }
        return nil
    }

    var body: some View {
        let a = fill(port(1)), b = fill(port(2))
        HStack(spacing: 2) {
            if mode.shows(1) { RadioButton(letter: "A", ant: ant, port: port(1), heldBy: heldBy(other: 1)) }
            ZStack {
                if a == nil && b == nil {
                    Rectangle().fill(Theme.row)
                } else if let a, let b {
                    HStack(spacing: 0) { Rectangle().fill(a); Rectangle().fill(b) }
                } else {
                    Rectangle().fill((a ?? b)!)
                }
                Text(ant.name)
                    .font(.system(size: Theme.fs(14), weight: .medium))
                    .foregroundStyle(a != nil || b != nil ? Theme.onSelected : Theme.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.fs(34), maxHeight: Theme.fs(34))
            .overlay(Rectangle().stroke(Theme.edge, lineWidth: Theme.lineWidth))
            if mode.shows(2) { RadioButton(letter: "B", ant: ant, port: port(2), heldBy: heldBy(other: 2)) }
        }
    }

    /// Letter of the other radio if it is using this antenna (the device may refuse to share it).
    private func heldBy(other id: Int) -> String? {
        guard let o = client.ports.first(where: { $0.id != id && mode.shows($0.id) }), o.rxant == ant.id || o.txant == ant.id else { return nil }
        return o.id == 1 ? "A" : "B"
    }
}

/// The "A" / "B" end caps: click to route that radio to this antenna.
struct RadioButton: View {
    @EnvironmentObject var client: AGClient
    let letter: String
    let ant: AntennaInfo
    let port: PortState?
    var heldBy: String? = nil

    private var rx: Bool { port?.rxant == ant.id }
    private var tx: Bool { port?.txant == ant.id }
    private var transmitting: Bool { (port?.tx ?? false) && tx }

    private var background: LinearGradient {
        if transmitting { return Theme.transmit }
        if (rx || tx), let port { return Theme.selected(port: port.id) }
        return Theme.row
    }

    var body: some View {
        Button {
            guard let port else { return }
            if rx || tx { client.clearAntenna(port: port.id) }
            else { client.selectAntenna(port: port.id, antenna: ant.id) }
        } label: {
            Text(letter).font(.system(size: Theme.fs(12), weight: .semibold)).foregroundStyle(rx || tx ? Theme.onSelected : Theme.text)
                .frame(width: Theme.fs(24), height: Theme.fs(34))
                .background(background)
                .overlay(Rectangle().stroke(Theme.edge, lineWidth: Theme.lineWidth))
                .opacity(heldBy != nil && !rx && !tx ? (Theme.scale > 1 ? 0.75 : 0.45) : 1)
        }
        .buttonStyle(.plain)
        .help(rx || tx ? "Release Radio \(letter)"
              : heldBy.map { "In use by Radio \($0) — the device may not allow both radios on one antenna" }
              ?? "Route Radio \(letter) to \(ant.name)")
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var client: AGClient
    var body: some View { LogLines(store: client.logStore) }
}

private struct LogLines: View {
    @ObservedObject var store: LogStore
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.lines) { l in
                        Text(l.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.lines.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }
}

// MARK: - Window roots (Settings and the protocol log are windows, so they can be moved)

struct SettingsWindowRoot: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("appearance") private var appearance = Appearance.light.rawValue
    /// Held here, outside the `.id(appearance)` rebuild, so switching theme doesn't throw away unsaved edits.
    @StateObject private var model = SettingsModel()

    var body: some View {
        let _ = Appearance.apply(appearance)
        SettingsView(close: { dismissWindow(id: "settings") }, model: model)
            .background(Theme.window)
            .preferredColorScheme(appearance == Appearance.light.rawValue ? .light : .dark)
            .id(appearance)
    }
}

struct LogWindowRoot: View {
    @AppStorage("appearance") private var appearance = Appearance.light.rawValue

    var body: some View {
        let _ = Appearance.apply(appearance)
        LogView()
            .frame(minWidth: 480, minHeight: 200)
            .background(Theme.window)
            .preferredColorScheme(appearance == Appearance.light.rawValue ? .light : .dark)
            .id(appearance)
    }
}
