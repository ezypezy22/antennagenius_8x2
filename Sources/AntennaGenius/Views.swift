import SwiftUI

enum AppInfo {
    /// From the bundle's Info.plist, which bundle.sh fills from the VERSION file.
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    // Shown in the About window — edit these to change what it says.
    static let author = "ezypezy22"
    static let repoURL = URL(string: "https://github.com/ezypezy22/antennagenius_8x2")!
}

/// Stand-in for @State: the SwiftUI macro plugin isn't shipped with the Command Line Tools.
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

// MARK: - Theme (mirrors the Windows panel: dark slate with a blue selection)

enum Theme {
    /// Color that resolves per appearance (the root view forces light or dark from the user's setting).
    private static func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let c = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    private static func grad(_ top: Color, _ bottom: Color) -> LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    static let window = dyn((0.94, 0.95, 0.96), (0.14, 0.15, 0.17))
    static let chrome = dyn((0.85, 0.87, 0.90), (0.20, 0.21, 0.24))
    static let text = dyn((0.08, 0.10, 0.13), (1, 1, 1))
    static let row = grad(dyn((0.98, 0.98, 0.99), (0.25, 0.30, 0.36)), dyn((0.86, 0.89, 0.93), (0.18, 0.22, 0.27)))
    static let button = grad(dyn((1, 1, 1), (0.34, 0.35, 0.38)), dyn((0.85, 0.86, 0.88), (0.16, 0.17, 0.19)))
    /// Per-radio selection colours, as in the Windows panel: A is green, B is blue.
    static let radioA = grad(Color(red: 0.10, green: 0.72, blue: 0.20), Color(red: 0.0, green: 0.50, blue: 0.08))
    static let radioB = grad(Color(red: 0.25, green: 0.60, blue: 1.0), Color(red: 0.05, green: 0.38, blue: 0.85))
    static func selected(port: Int) -> LinearGradient { port == 1 ? radioA : radioB }
    static let transmit = grad(Color(red: 1.0, green: 0.38, blue: 0.32), Color(red: 0.75, green: 0.12, blue: 0.10))
    static let edge = dyn((0.62, 0.65, 0.70), (0.0, 0.0, 0.0))
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var discovery: Discovery
    @EnvironmentObject var client: AGClient
    @StateObject private var showSettings = Box(false)
    @StateObject private var showLog = Box(false)
    @StateObject private var showAbout = Box(false)
    @AppStorage("darkMode") private var darkMode = false

    var body: some View {
        Group {
            if client.state == .connected {
                PanelView(showSettings: showSettings, showLog: showLog, showAbout: showAbout)
            } else {
                ConnectView()
            }
        }
        .frame(width: client.state == .connected ? 230 : 320)
        .background(Theme.window)
        .preferredColorScheme(darkMode ? .dark : .light)
        .sheet(isPresented: $showSettings.value) { SettingsView(close: { showSettings.value = false }) }
        .sheet(isPresented: $showAbout.value) { AboutView(close: { showAbout.value = false }) }
        .sheet(isPresented: $showLog.value) {
            VStack(spacing: 0) {
                LogView()
                HStack { Spacer(); Button("Close") { showLog.value = false }.keyboardShortcut(.cancelAction) }.padding(8)
            }
            .frame(width: 640, height: 340)
        }
    }
}

// MARK: - Connect screen

struct ConnectView: View {
    @EnvironmentObject var discovery: Discovery
    @EnvironmentObject var client: AGClient
    @AppStorage("darkMode") private var darkMode = false
    @AppStorage("lastIP") private var lastIP = ""
    @StateObject private var waited = Box(false)
    @StateObject private var typedIP = Box("")

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button { darkMode.toggle() } label: { Image(systemName: darkMode ? "sun.max" : "moon") }
                    .buttonStyle(.plain).help(darkMode ? "Switch to light mode" : "Switch to dark mode")
            }
            Text("Antenna Genius").font(.headline)
            Text("Version \(AppInfo.version)").font(.caption2).foregroundStyle(.secondary)
            if discovery.devices.isEmpty {
                ProgressView().controlSize(.small)
                Text("Listening for devices on UDP 9007…").font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ForEach(discovery.devices) { d in
                    Button { connect(d) } label: {
                        VStack(spacing: 2) {
                            Text(d.name).font(.system(size: 14, weight: .semibold))
                            Text("\(d.ip) · FW \(d.version)").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Theme.row, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.edge))
                    }
                    .buttonStyle(.plain)
                    .disabled(client.state == .connecting)
                }
            }
            switch client.state {
            case .connecting: ProgressView().controlSize(.small)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            default: EmptyView()
            }
            if let err = discovery.error {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if discovery.devices.isEmpty && waited.value { fallback }
        }
        .padding(20)
        .frame(minHeight: 180)
        .onChange(of: discovery.devices) { _, d in autoConnectIfSingle(d) }
        .onAppear {
            autoConnectIfSingle(discovery.devices)
            if typedIP.value.isEmpty { typedIP.value = lastIP }
        }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            waited.value = true
        }
    }

    /// Shown when nothing has been heard for a few seconds — usually missing Local Network permission.
    private var fallback: some View {
        VStack(spacing: 8) {
            Divider()
            Text("No device heard. If macOS asked for Local Network access, allow it — then check System Settings › Privacy & Security › Local Network.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open Local Network settings") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                    NSWorkspace.shared.open(u)
                }
            }.controlSize(.small)
            HStack {
                TextField("Device IP, e.g. 10.43.10.59", text: $typedIP.value)
                    .textFieldStyle(.roundedBorder).onSubmit(connectTyped)
                Button("Connect", action: connectTyped).disabled(typedIP.value.isEmpty)
            }
        }
    }

    private func connectTyped() {
        let ip = typedIP.value.trimmingCharacters(in: .whitespaces)
        guard let d = DiscoveredDevice(beacon: "AG ip=\(ip) port=9007 serial=manual-\(ip) name=\(ip)") else { return }
        connect(d)
    }

    private func connect(_ d: DiscoveredDevice) {
        lastIP = d.ip
        client.autoConnect = true
        client.connect(to: d)
    }

    private func autoConnectIfSingle(_ d: [DiscoveredDevice]) {
        guard client.autoConnect, d.count == 1, client.state == .disconnected, let dev = d.first else { return }
        connect(dev)
    }
}

// MARK: - Main panel

struct PanelView: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var showSettings: Box<Bool>
    @ObservedObject var showLog: Box<Bool>
    @ObservedObject var showAbout: Box<Bool>
    @AppStorage("darkMode") private var darkMode = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if let err = client.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { client.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(6).background(Color.orange.opacity(0.18))
            }
            Text(client.deviceName.isEmpty ? (client.connectedDevice?.name ?? "Antenna Genius") : client.deviceName)
                .font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Theme.chrome)
            HStack(spacing: 2) {
                ForEach(client.ports, id: \.id) { SourceBandHeader(port: $0) }
            }
            .padding(.horizontal, 2)
            VStack(spacing: 2) {
                ForEach(client.antennas) { AntennaRow(ant: $0) }
            }
            .padding(.horizontal, 2).padding(.top, 2).padding(.bottom, 2)
            Text("Version \(AppInfo.version)").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.bottom, 8)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Menu {
                Button("Settings…") { showSettings.value = true }
                Toggle("Dark mode", isOn: $darkMode)
                Button("Protocol log…") { showLog.value = true }
                Divider()
                Button("About Antenna Genius…") { showAbout.value = true }
                Divider()
                Button("Disconnect") { client.autoConnect = false; client.disconnect() }
                Button("Quit Antenna Genius") { AppDelegate.quit() }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape.fill").foregroundStyle(.gray)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Image(systemName: "chevron.down").foregroundStyle(.gray)
        }
        .font(.system(size: 13, weight: .bold))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Theme.chrome.opacity(0.7))
    }
}

struct PanelButton: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(Theme.button, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.edge))
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
                .opacity(port.source == "MANUAL" ? 1 : 0.6)
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

    private func port(_ id: Int) -> PortState? { client.ports.first { $0.id == id } }

    /// Background for one radio's share of the name cell (transmit overrides the radio colour).
    private func fill(_ p: PortState?) -> LinearGradient? {
        guard let p else { return nil }
        if p.txant == ant.id { return Theme.transmit }
        if p.rxant == ant.id { return Theme.selected(port: p.id) }
        return nil
    }

    var body: some View {
        let a = fill(port(1)), b = fill(port(2))
        HStack(spacing: 2) {
            RadioButton(letter: "A", ant: ant, port: port(1), heldBy: heldBy(other: 1))
            ZStack {
                if a == nil && b == nil {
                    Rectangle().fill(Theme.row)
                } else if let a, let b {
                    HStack(spacing: 0) { Rectangle().fill(a); Rectangle().fill(b) }
                } else {
                    Rectangle().fill((a ?? b)!)
                }
                Text(ant.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(a != nil || b != nil ? Color.white : Theme.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
            .overlay(Rectangle().stroke(Theme.edge))
            RadioButton(letter: "B", ant: ant, port: port(2), heldBy: heldBy(other: 2))
        }
    }

    /// Letter of the other radio if it is using this antenna (the device may refuse to share it).
    private func heldBy(other id: Int) -> String? {
        guard let o = client.ports.first(where: { $0.id != id }), o.rxant == ant.id || o.txant == ant.id else { return nil }
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

    private var background: LinearGradient {
        if tx { return Theme.transmit }
        if rx, let port { return Theme.selected(port: port.id) }
        return Theme.row
    }

    var body: some View {
        Button {
            guard let port else { return }
            if rx || tx { client.clearAntenna(port: port.id) }
            else { client.selectAntenna(port: port.id, antenna: ant.id) }
        } label: {
            Text(letter).font(.system(size: 12, weight: .semibold)).foregroundStyle(rx || tx ? Color.white : Theme.text)
                .frame(width: 24, height: 34)
                .background(background)
                .overlay(Rectangle().stroke(Theme.edge))
                .opacity(heldBy != nil && !rx && !tx ? 0.45 : 1)
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
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(client.log.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(size: 11, design: .monospaced)).id(i).textSelection(.enabled)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: client.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
    }
}

// MARK: - Settings (laid out like the Windows app: menu on the left, green page header, Save / Cancel)

enum SettingsPage: String, CaseIterable, Identifiable {
    case info = "Basic information", antennas = "Antennas", outputs = "Output relays", bands = "Bands", network = "Network settings", stack = "Stack settings", advanced = "Advanced options"
    var id: String { rawValue }
}

/// Editable copy of an antenna, committed on Save.
final class AntennaDraft: ObservableObject {
    @Published var id = 1
    @Published var name = ""
    @Published var tx = 0
    @Published var rx = 0
    @Published var inband = 0
    func load(_ a: AntennaInfo) { id = a.id; name = a.name; tx = a.tx; rx = a.rx; inband = a.inband }
    var info: AntennaInfo { AntennaInfo(id: id, name: name, tx: tx, rx: rx, inband: inband) }
}

final class BandDraft: ObservableObject {
    @Published var id = 1
    @Published var name = ""
    @Published var start = ""
    @Published var stop = ""
    func load(_ b: BandInfo) { id = b.id; name = b.name; start = b.freqStart; stop = b.freqStop }
    var info: BandInfo { BandInfo(id: id, name: name, freqStart: start, freqStop: stop) }
}

final class SettingsModel: ObservableObject {
    @Published var page = SettingsPage.info
    @Published var name = ""
    @Published var net = NetworkConfig()
    @Published var confirmNetwork = false
    @Published var confirmReboot = false
    @Published var confirmReset = false
    @Published var inbandPort = 0
    @Published var stack = StackConfig()
    @Published var groups: [OutputGroup] = []
    @Published var outputs: [OutputDef] = []
    @Published var selectedGroup = 0
    @Published var confirmInitOutputs = false
    @Published var validation: String?
    let antenna = AntennaDraft()
    let band = BandDraft()
    private var loaded = false

    @MainActor func load(from c: AGClient) {
        guard !loaded else { return }
        loaded = true
        name = c.deviceName
        inbandPort = c.inbandPort
        stack = c.stack
        groups = c.groups
        outputs = c.outputs
        selectedGroup = c.groups.first?.id ?? 0
        net = c.network ?? NetworkConfig()
        if let a = c.antennas.first { antenna.load(a) }
        if let b = c.bands.first(where: { $0.id != 0 }) { band.load(b) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var client: AGClient
    let close: () -> Void
    @StateObject private var model = SettingsModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Text("Antenna Genius Settings").font(.headline); Spacer() }.padding(10)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPage.allCases) { p in
                        Button { model.page = p } label: {
                            Text(p.rawValue).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 7)
                                .background(model.page == p ? Color.yellow.opacity(0.28) : .clear)
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(width: 190)
                Divider()
                VStack(spacing: 0) {
                    Text(model.page.rawValue).foregroundStyle(.white).fontWeight(.medium)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(red: 0.0, green: 0.50, blue: 0.10))
                    Group {
                        switch model.page {
                        case .info: InfoPage(model: model)
                        case .antennas: AntennaSettingsPage(draft: model.antenna)
                        case .bands: BandSettingsPage(draft: model.band)
                        case .network: NetworkPage(model: model)
                        case .outputs: OutputRelaysPage(model: model)
                        case .stack: StackPage(model: model)
                        case .advanced: AdvancedPage(model: model, close: close)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(Rectangle().stroke(Theme.edge))
                    .padding(8)
                }
            }
            Divider()
            HStack {
                if let v = model.validation { Label(v, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption) }
                Spacer()
                Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }.keyboardShortcut(.defaultAction)
                Button { close() } label: { Label("Cancel", systemImage: "xmark") }.keyboardShortcut(.cancelAction)
            }.padding(10)
        }
        .frame(width: 740, height: 520)
        .onAppear { model.load(from: client) }
        .confirmationDialog("Apply network changes?", isPresented: $model.confirmNetwork, titleVisibility: .visible) {
            Button("Apply and reboot device", role: .destructive) {
                client.saveNetwork(model.net)
                close()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Antenna Genius will reboot and be offline for about 20 seconds. If you set a static address, reconnect to the new IP.")
        }
    }

    /// Saves whatever was edited. Network changes that force a reboot ask first.
    private func save() {
        model.validation = nil
        let n = model.net
        if !n.dhcp {
            guard [n.address, n.netmask, n.gateway].allSatisfy(NetworkConfig.validIPv4) else {
                model.validation = "Address, netmask and gateway must be valid IPv4 addresses."
                model.page = .network
                return
            }
        }
        if model.name != client.deviceName {
            guard !model.name.trimmingCharacters(in: .whitespaces).isEmpty else {
                model.validation = "Device name can't be empty."; model.page = .info; return
            }
            client.saveName(model.name)
        }
        for g in model.groups where client.groups.first(where: { $0.id == g.id }).map({ $0 != g }) ?? g.inUse { client.saveGroup(g) }
        for o in model.outputs where client.outputs.first(where: { $0.id == o.id }).map({ $0 != o }) ?? o.inUse { client.saveOutput(o) }
        if model.stack != client.stack {
            if model.stack.inUse && model.stack.serial.isEmpty {
                model.validation = "Choose the Antenna Genius to stack with."; model.page = .stack; return
            }
            client.saveStack(model.stack)
        }
        if model.inbandPort != client.inbandPort { client.setInbandPort(model.inbandPort) }
        if let a = client.antennas.first(where: { $0.id == model.antenna.id }), a != model.antenna.info {
            client.saveAntenna(model.antenna.info)
        }
        if let b = client.bands.first(where: { $0.id == model.band.id }), b != model.band.info {
            client.saveBand(model.band.info)
        }
        if let cur = client.network, cur != n {
            let reboots = cur.dhcp != n.dhcp || (!n.dhcp && (cur.address != n.address || cur.netmask != n.netmask || cur.gateway != n.gateway))
            if reboots { model.confirmNetwork = true; return }
            client.saveNetwork(n)
        }
        close()
    }
}

struct InfoPage: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device name:").fontWeight(.semibold)
            TextField("Device name", text: $model.name).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            Divider().padding(.vertical, 6)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("App version").foregroundStyle(.secondary); Text(AppInfo.version) }
                GridRow { Text("Address").foregroundStyle(.secondary); Text(client.connectedDevice?.ip ?? "") }
                GridRow { Text("Serial").foregroundStyle(.secondary); Text(client.connectedDevice?.serial ?? "") }
                GridRow { Text("Firmware").foregroundStyle(.secondary); Text(client.firmware) }
                GridRow { Text("Mode").foregroundStyle(.secondary); Text(client.connectedDevice?.mode ?? "") }
            }.font(.callout)
        }.padding(12)
    }
}

struct NetworkPage: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Obtain an IP address automatically (DHCP)", isOn: $model.net.dhcp)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("IP address"); TextField("", text: $model.net.address).textFieldStyle(.roundedBorder).frame(width: 200) }
                GridRow { Text("Subnet mask"); TextField("", text: $model.net.netmask).textFieldStyle(.roundedBorder).frame(width: 200) }
                GridRow { Text("Gateway"); TextField("", text: $model.net.gateway).textFieldStyle(.roundedBorder).frame(width: 200) }
            }
            .disabled(model.net.dhcp).opacity(model.net.dhcp ? 0.5 : 1)
            Divider().padding(.vertical, 4)
            Grid(alignment: .leading, horizontalSpacing: 12) {
                GridRow { Text("Remote access password"); SecureField("", text: $model.net.auth).textFieldStyle(.roundedBorder).frame(width: 200) }
            }
            Text("Changing DHCP or the static address reboots the device (about 20 seconds offline).")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }
}

struct AntennaSettingsPage: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var draft: AntennaDraft

    private func bit(_ mask: Binding<Int>, _ band: Int) -> Binding<Bool> {
        Binding(get: { mask.wrappedValue & (1 << band) != 0 },
                set: { on in if on { mask.wrappedValue |= 1 << band } else { mask.wrappedValue &= ~(1 << band) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Antenna", selection: Binding(get: { draft.id }, set: { id in
                if let a = client.antennas.first(where: { $0.id == id }) { draft.load(a) }
            })) {
                ForEach(client.antennas) { Text("\($0.id) — \($0.name)").tag($0.id) }
            }
            TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
            Text("Bands this antenna may be used on").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("Band").foregroundStyle(.secondary); Text("RX").foregroundStyle(.secondary)
                    Text("TX").foregroundStyle(.secondary); Text("In-band").foregroundStyle(.secondary)
                }
                ForEach(client.bands) { b in
                    GridRow {
                        Text(b.name)
                        Toggle("", isOn: bit($draft.rx, b.id)).labelsHidden()
                        Toggle("", isOn: bit($draft.tx, b.id)).labelsHidden()
                        Toggle("", isOn: bit($draft.inband, b.id)).labelsHidden()
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }.padding(12)
    }
}

struct BandSettingsPage: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var draft: BandDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Band", selection: Binding(get: { draft.id }, set: { id in
                if let b = client.bands.first(where: { $0.id == id }) { draft.load(b) }
            })) {
                ForEach(client.bands.filter { $0.id != 0 }) { Text($0.name).tag($0.id) }
            }
            TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
            TextField("Start (MHz)", text: $draft.start).textFieldStyle(.roundedBorder)
            TextField("Stop (MHz)", text: $draft.stop).textFieldStyle(.roundedBorder)
            Spacer()
        }.padding(12)
    }
}

struct AdvancedPage: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var model: SettingsModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("In-band port", selection: $model.inbandPort) {
                Text("Not configured").tag(0)
                Text("Radio A").tag(1)
                Text("Radio B").tag(2)
            }
            .frame(maxWidth: 320)
            Text("Which radio port the in-band antenna handling applies to.").font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            HStack {
                Button("Reboot device…") { model.confirmReboot = true }
                Button("Restore factory defaults…", role: .destructive) { model.confirmReset = true }
            }
            Text("Reboot takes the device offline for about 20 seconds. Factory defaults erase antenna names and band assignments, band ranges and network settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .confirmationDialog("Reboot the Antenna Genius?", isPresented: $model.confirmReboot, titleVisibility: .visible) {
            Button("Reboot", role: .destructive) { client.reboot(); close() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It will be unresponsive for about 20 seconds and this app will disconnect.") }
        .confirmationDialog("Restore factory defaults?", isPresented: $model.confirmReset, titleVisibility: .visible) {
            Button("Erase and restore defaults", role: .destructive) { client.factoryReset(); close() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This erases all configuration on the device, including its network settings, and reboots it. It cannot be undone.") }
    }
}

struct StackPage: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var model: SettingsModel

    /// Discovered peers, plus the currently configured serial if that unit isn't answering right now.
    private var choices: [(serial: String, label: String)] {
        var list = client.stackPeers.map { (serial: $0.serial, label: $0.name.isEmpty ? $0.serial : "\($0.serial) — \($0.name)") }
        if !model.stack.serial.isEmpty, !list.contains(where: { $0.serial == model.stack.serial }) {
            list.append((model.stack.serial, model.stack.serial))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable stacking (16x2)", isOn: $model.stack.inUse).fontWeight(.semibold)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("AG Serial number:").fontWeight(.semibold)
                    Picker("", selection: $model.stack.serial) {
                        Text("").tag("")
                        ForEach(choices, id: \.serial) { Text($0.label).tag($0.serial) }
                    }.labelsHidden().frame(width: 260)
                }
                GridRow {
                    Text("Switching type:").fontWeight(.semibold)
                    Picker("", selection: $model.stack.mode) {
                        Text("External AB switches").tag(0)
                        Text("Using ports 7 & 8").tag(1)
                    }.labelsHidden().frame(width: 260)
                }
            }
            .disabled(!model.stack.inUse).opacity(model.stack.inUse ? 1 : 0.5)
            HStack {
                Button("Rescan network") { client.loadStackPeers() }.controlSize(.small)
                if client.stackPeers.isEmpty {
                    Text("No other Antenna Genius found on the network.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Stacking pairs two Antenna Genius units into a 16x2 switch. Changing the switching type changes the antenna list.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }
}

/// Output relay designer, laid out like the Windows app: group list with "+" on the left, editor on the right.
/// Groups pick *when* outputs apply (by antenna or band); outputs pick *which relays* switch.
struct OutputRelaysPage: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var model: SettingsModel

    private var usedGroups: [OutputGroup] { model.groups.filter(\.inUse) }
    private var gi: Int? { model.groups.firstIndex { $0.id == model.selectedGroup && $0.inUse } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 160)
            Divider()
            VStack(spacing: 0) {
                if let i = gi {
                    ScrollView { editor(i).padding(12) }
                } else {
                    Spacer()
                    Text("Please add or select a group on the left menu").font(.callout)
                    Spacer()
                }
                Divider()
                relayStrip.padding(8)
            }
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Initialize output relays?", isPresented: $model.confirmInitOutputs, titleVisibility: .visible) {
            Button("Initialize", role: .destructive) {
                client.initOutputs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The device documentation describes this as the initialization step before groups and outputs are configured. It resets the output and group configuration.")
        }
    }

    // MARK: Left: groups

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output groups").fontWeight(.bold).padding(.horizontal, 8).padding(.top, 8)
            ForEach(usedGroups) { g in
                Button { model.selectedGroup = g.id } label: {
                    Text(g.name.isEmpty ? "Group \(g.id)" : g.name).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(model.selectedGroup == g.id ? Color.yellow.opacity(0.28) : .clear)
                }.buttonStyle(.plain)
            }
            Button { addGroup() } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundStyle(Color(red: 0, green: 0.55, blue: 0.1))
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 4).help("Add output group")
            Spacer()
            Button("Initialize…") { model.confirmInitOutputs = true }
                .controlSize(.small).padding(8)
                .help("Runs the device's output init command. Normally not needed.")
        }
    }

    /// Reuse a free slot the device already reports, otherwise take the next id.
    private func addGroup() {
        if let i = model.groups.firstIndex(where: { !$0.inUse }) {
            model.groups[i].inUse = true
            if model.groups[i].name.isEmpty { model.groups[i].name = "Group \(model.groups[i].id)" }
            model.selectedGroup = model.groups[i].id
        } else {
            var g = OutputGroup(id: (model.groups.map(\.id).max() ?? 0) + 1)
            g.inUse = true; g.name = "Group \(g.id)"
            model.groups.append(g)
            model.selectedGroup = g.id
        }
    }

    private func addOutput() {
        if let i = model.outputs.firstIndex(where: { !$0.inUse }) {
            model.outputs[i].inUse = true
            model.outputs[i].group = model.selectedGroup
            if model.outputs[i].name.isEmpty { model.outputs[i].name = "Output \(model.outputs[i].id)" }
        } else {
            var o = OutputDef(id: (model.outputs.map(\.id).max() ?? 0) + 1)
            o.inUse = true; o.group = model.selectedGroup; o.name = "Output \(o.id)"
            model.outputs.append(o)
        }
    }

    // MARK: Right: editor

    private func editor(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Group name", text: $model.groups[i].name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button("Delete group", role: .destructive) { model.groups[i].inUse = false }.controlSize(.small)
            }
            Picker("Follows", selection: $model.groups[i].mode) {
                Text("Selected antenna").tag("ANT")
                Text("Selected band").tag("BAND")
            }.pickerStyle(.segmented).frame(maxWidth: 320)
            if model.groups[i].mode == "ANT" {
                Picker("Antenna", selection: $model.groups[i].antenna) {
                    Text("None").tag(0)
                    ForEach(client.antennas) { Text("\($0.id) — \($0.name)").tag($0.id) }
                }.frame(maxWidth: 320)
            } else {
                Text("Bands").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading) {
                    ForEach(client.bands.filter { $0.id != 0 }) { b in
                        Toggle(b.name, isOn: Binding(
                            get: { model.groups[i].bands & (1 << b.id) != 0 },
                            set: { on in if on { model.groups[i].bands |= 1 << b.id } else { model.groups[i].bands &= ~(1 << b.id) } }))
                    }
                }
            }
            Toggle("Allow no output active", isOn: $model.groups[i].allowNone)
            Divider()
            HStack {
                Text("Outputs").font(.subheadline.weight(.semibold))
                Button { addOutput() } label: {
                    Image(systemName: "plus").fontWeight(.bold).foregroundStyle(Color(red: 0, green: 0.55, blue: 0.1))
                }.buttonStyle(.plain).help("Add output")
            }
            ForEach(model.outputs.indices.filter { model.outputs[$0].inUse && model.outputs[$0].group == model.selectedGroup }, id: \.self) { outputRow($0) }
            Text("Activate switches that output's relays on the real device right away — use it for testing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func outputRow(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Output name", text: $model.outputs[i].name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Toggle("Exclusive (TRX)", isOn: $model.outputs[i].trx).help("Activating this output switches off the others in its group")
                Spacer()
                Button("Activate") { client.activateOutput(model.outputs[i].id) }.controlSize(.small)
                Button { model.outputs[i].inUse = false } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete output")
            }
            HStack(spacing: 10) {
                Text("Relays").font(.caption).foregroundStyle(.secondary)
                ForEach(0..<8, id: \.self) { r in
                    Toggle("\(r + 1)", isOn: Binding(
                        get: { model.outputs[i].state & (1 << r) != 0 },
                        set: { on in if on { model.outputs[i].state |= 1 << r } else { model.outputs[i].state &= ~(1 << r) } }))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(8).background(Theme.chrome.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Live state of the eight relays as reported by the device.
    private var relayStrip: some View {
        HStack(spacing: 10) {
            Text("Relays (live)").font(.caption).foregroundStyle(.secondary)
            ForEach(0..<8, id: \.self) { i in
                VStack(spacing: 2) {
                    Circle().fill(client.relayState & (1 << i) != 0 ? Color.green : Color.gray.opacity(0.35))
                        .frame(width: 14, height: 14).overlay(Circle().stroke(Theme.edge))
                    Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

struct AboutView: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 38)).foregroundStyle(Color(red: 0, green: 0.55, blue: 0.1))
            Text("Antenna Genius for macOS").font(.title3.bold())
            Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Created by \(AppInfo.author)")
            Link(AppInfo.repoURL.absoluteString, destination: AppInfo.repoURL).font(.callout)
            Text("An independent control app for the 4O3A Antenna Genius 8x2. Not affiliated with or endorsed by 4O3A Signature.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
            Button("Close", action: close).keyboardShortcut(.cancelAction).padding(.top, 6)
        }
        .padding(24).frame(width: 340)
    }
}
