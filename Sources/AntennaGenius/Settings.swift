import SwiftUI

// MARK: - Settings (laid out like the Windows app: menu on the left, green page header, Save / Cancel)

enum SettingsPage: String, CaseIterable, Identifiable {
    case info = "Basic information", antennas = "Antennas", outputs = "Output relays", bands = "Bands", flex = "FlexRadio", cat = "CAT (this Mac)", bcd = "BCD", p2p = "P2P", network = "Network settings", stack = "Stack settings", advanced = "Advanced options"
    var id: String { rawValue }
    /// Sub-items shown indented under "Bands".
    var isSub: Bool { self == .flex || self == .cat || self == .bcd || self == .p2p }
    /// Green header text; the FlexRadio page draws its own per-port headers.
    var header: String? {
        switch self {
        case .flex: return nil
        case .bands: return "Bands configuration"
        case .cat: return "Band source via CAT (Hamlib rigctld or flrig on this Mac)"
        case .bcd: return "Band source via BCD"
        case .p2p: return "Band source via Pin to Port"
        default: return rawValue
        }
    }
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
    @Published var antennas: [AntennaInfo] = []
    @Published var editingAntenna: Int?
    @Published var bands: [BandInfo] = []
    @Published var flex: [Int: FlexPortConfig] = [:]
    /// A backup file the user picked, awaiting confirmation before it is sent to the device.
    @Published var restoreFrom: DeviceBackup?
    @Published var confirmRestore = false
    /// Second entry of a new remote access password.
    @Published var authConfirm = ""
    /// CAT settings per radio port; kept by the app, not the device.
    @Published var cat: [Int: CatConfig] = [:]
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
        antennas = c.antennas
        bands = c.bands
        flex = c.flexConfigs
        cat = [1: CatConfig.load(port: 1), 2: CatConfig.load(port: 2)]
    }
}

struct SettingsView: View {
    @EnvironmentObject var client: AGClient
    @EnvironmentObject var catManager: CatManager
    let close: () -> Void
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Text("Antenna Genius Settings").font(.headline); Spacer() }.padding(10)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPage.allCases) { p in
                        Button { model.page = p } label: {
                            Text(p.rawValue).fontWeight(p.isSub ? .regular : .semibold).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, p.isSub ? 22 : 8).padding(.trailing, 8).padding(.vertical, p.isSub ? 4 : 7)
                                .background(model.page == p ? Color.yellow.opacity(0.28) : .clear)
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(width: 190)
                Divider()
                VStack(spacing: 0) {
                    if let header = model.page.header {
                        Text(header)
                            .foregroundStyle(.white).fontWeight(.medium)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color(red: 0.0, green: 0.50, blue: 0.10))
                    }
                    Group {
                        switch model.page {
                        case .info: InfoPage(model: model)
                        case .antennas: AntennaSettingsPage(model: model)
                        case .bands: BandSettingsPage(model: model)
                        case .flex: FlexPage(model: model)
                        case .cat: CatPage(model: model)
                        case .bcd: BCDPage()
                        case .p2p: P2PPage()
                        case .network: NetworkPage(model: model)
                        case .outputs: OutputRelaysPage(model: model)
                        case .stack: StackPage(model: model)
                        case .advanced: AdvancedPage(model: model, close: close)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(Rectangle().stroke(Theme.edge, lineWidth: Theme.lineWidth))
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
        .frame(minWidth: 740, idealWidth: 760, minHeight: 600, idealHeight: 640)
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
        for (id, c) in model.cat where c.kind != .off {
            guard NetworkConfig.validHost(c.host), c.port > 0 else {
                model.validation = "CAT for Radio \(id == 1 ? "A" : "B"): enter the address of the Mac running \(c.kind.label) and its port."
                model.page = .cat
                return
            }
        }
        for (id, c) in model.cat where c != CatConfig.load(port: id) { c.save(port: id) }
        catManager.reload()
        if !n.auth.isEmpty {
            guard PasswordPolicy.isAcceptable(n.auth) else {
                model.validation = "The new remote access password doesn't meet the requirements listed on the Network page."
                model.page = .network
                return
            }
            guard n.auth == model.authConfirm else {
                model.validation = "The two remote access passwords don't match."
                model.page = .network
                return
            }
        }
        if !NetworkConfig.isSafeToken(n.auth) {
            model.validation = "The remote access password can't contain spaces or control characters."
            model.page = .network
            return
        }
        if model.name != client.deviceName {
            guard !model.name.trimmingCharacters(in: .whitespaces).isEmpty else {
                model.validation = "Device name can't be empty."; model.page = .info; return
            }
            client.saveName(model.name)
        }
        for g in model.groups where client.groups.first(where: { $0.id == g.id }).map({ $0 != g }) ?? g.inUse { client.saveGroup(g) }
        for o in model.outputs where client.outputs.first(where: { $0.id == o.id }).map({ $0 != o }) ?? o.inUse { client.saveOutput(o) }
        for (port, cfg) in model.flex where client.flexConfigs[port].map({ $0 != cfg }) ?? false {
            client.saveFlex(port: port, cfg)
        }
        if model.stack != client.stack {
            if model.stack.inUse && model.stack.serial.isEmpty {
                model.validation = "Choose the Antenna Genius to stack with."; model.page = .stack; return
            }
            client.saveStack(model.stack)
        }
        if model.inbandPort != client.inbandPort { client.setInbandPort(model.inbandPort) }
        for a in model.antennas where client.antennas.first(where: { $0.id == a.id }).map({ $0 != a }) ?? false {
            client.saveAntenna(a)
        }
        let changedBands = model.bands.filter { b in b.id != 0 && client.bands.first(where: { $0.id == b.id }).map { $0 != b } ?? false }
        for b in changedBands {
            guard let lo = Double(b.freqStart), let hi = Double(b.freqStop), lo >= 0, hi >= lo else {
                model.validation = "Band \(b.id) (\(b.name)): start and stop must be numbers in MHz, with stop not below start."
                model.page = .bands
                return
            }
            if b.name.trimmingCharacters(in: .whitespaces).isEmpty {
                model.validation = "Band \(b.id) needs a name."; model.page = .bands; return
            }
        }
        for var b in changedBands {
            b.freqStart = String(format: "%.6f", Double(b.freqStart) ?? 0)
            b.freqStop = String(format: "%.6f", Double(b.freqStop) ?? 0)
            client.saveBand(b)
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
    @EnvironmentObject var client: AGClient
    @ObservedObject var model: SettingsModel
    private var changed: Bool { !model.net.auth.isEmpty }

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
                GridRow {
                    Text("New remote access password")
                    SecureField(model.net.passwordSet ? "Unchanged" : "None set", text: $model.net.auth)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
                if changed {
                    GridRow { Text("Confirm password"); SecureField("", text: $model.authConfirm).textFieldStyle(.roundedBorder).frame(width: 200) }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        PasswordRules(password: model.net.auth, confirm: model.authConfirm)
                    }
                }
            }
            if !changed {
                Text(model.net.passwordSet
                     ? "A password is set. The device doesn't reveal it; leave this empty to keep it, or type a new one to replace it."
                     : "No remote access password is set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Changing DHCP or the static address reboots the device (about 20 seconds offline).")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }
}

/// Strength meter and the checklist of password rules, shown while a new remote access password is typed.
struct PasswordRules: View {
    let password: String
    let confirm: String

    private func color(_ s: PasswordPolicy.Strength) -> Color {
        switch s {
        case .weak: return .red
        case .medium: return .orange
        case .strong: return Color(red: 0.55, green: 0.75, blue: 0.1)
        case .veryStrong: return .green
        }
    }

    var body: some View {
        let strength = PasswordPolicy.strength(password)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(PasswordPolicy.Strength.allCases, id: \.rawValue) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(!password.isEmpty && level.rawValue <= strength.rawValue ? color(strength) : Color.secondary.opacity(0.25))
                            .frame(width: 46, height: 6)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: strength)
                Text(password.isEmpty ? "" : strength.label).font(.caption.weight(.semibold)).foregroundStyle(color(strength))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Password strength")
            .accessibilityValue(password.isEmpty ? "Empty" : strength.label)
            ForEach(PasswordPolicy.requirements(password)) { r in
                Label(r.label, systemImage: r.met ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(r.met ? .green : .secondary)
            }
            if !confirm.isEmpty || PasswordPolicy.isAcceptable(password) {
                let same = confirm == password
                Label(same ? "Passwords match" : "Passwords don't match", systemImage: same ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(same ? .green : .red)
            }
        }
        .font(.caption)
    }
}

/// Antennas page, like the Windows app: every antenna with a name, a summary of its bands and a button
/// that opens the Antenna TX/RX table.
struct AntennaSettingsPage: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var model: SettingsModel

    /// Names of the bands the antenna is used on (the "None" band is not listed); "None" if there are none.
    private func summary(_ a: AntennaInfo) -> String {
        let used = client.bands.filter { $0.id != 0 && (a.rx | a.tx | a.inband) & (1 << $0.id) != 0 }
        return used.isEmpty ? "None" : used.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Name:").fontWeight(.bold)
                    Text("Bands:").fontWeight(.bold)
                }
                ForEach(model.antennas.indices, id: \.self) { i in
                    GridRow {
                        TextField("", text: $model.antennas[i].name).textFieldStyle(.roundedBorder).frame(width: 190)
                        HStack(spacing: 0) {
                            Text(summary(model.antennas[i]))
                                .fontWeight(.bold).foregroundStyle(Color(red: 0, green: 0.5, blue: 0.1)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                            Button { model.editingAntenna = model.antennas[i].id } label: {
                                Image(systemName: "checklist").frame(width: 34, height: 22)
                                    .background(Theme.button)
                            }
                            .buttonStyle(.plain).help("Choose RX, TX and in-band bands")
                        }
                        .frame(width: 330, height: 24)
                        .overlay(Rectangle().stroke(Theme.edge, lineWidth: Theme.lineWidth))
                    }
                }
            }
            .padding(12)
        }
        .sheet(isPresented: Binding(get: { model.editingAntenna != nil }, set: { if !$0 { model.editingAntenna = nil } })) {
            if let id = model.editingAntenna, let i = model.antennas.firstIndex(where: { $0.id == id }) {
                AntennaBandsSheet(antenna: model.antennas[i], bands: client.bands,
                                  accept: { model.antennas[i] = $0; model.editingAntenna = nil },
                                  cancel: { model.editingAntenna = nil })
            }
        }
    }
}

/// The "Antenna TX/RX" pop-up: one row per band with RX, TX and in-band (INB) checkboxes.
struct AntennaBandsSheet: View {
    @StateObject private var draft: Box<AntennaInfo>
    let bands: [BandInfo]
    let accept: (AntennaInfo) -> Void
    let cancel: () -> Void

    init(antenna: AntennaInfo, bands: [BandInfo], accept: @escaping (AntennaInfo) -> Void, cancel: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: Box(antenna))
        self.bands = bands; self.accept = accept; self.cancel = cancel
    }

    private func bit(_ keyPath: WritableKeyPath<AntennaInfo, Int>, _ band: Int) -> Binding<Bool> {
        Binding(get: { draft.value[keyPath: keyPath] & (1 << band) != 0 },
                set: { on in
                    if on { draft.value[keyPath: keyPath] |= 1 << band } else { draft.value[keyPath: keyPath] &= ~(1 << band) }
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Antenna TX/RX").font(.headline).padding(10)
            Divider()
            ScrollView {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Text("Band").fontWeight(.bold).frame(maxWidth: .infinity, alignment: .leading)
                        Text("RX").fontWeight(.bold).frame(width: 60)
                        Text("TX").fontWeight(.bold).frame(width: 60)
                        Text("INB").fontWeight(.bold).frame(width: 60)
                    }.padding(.vertical, 6)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(bands) { b in
                        GridRow {
                            Text(b.id == 0 ? "None" : b.name).frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: bit(\.rx, b.id)).labelsHidden().frame(width: 60)
                            Toggle("", isOn: bit(\.tx, b.id)).labelsHidden().frame(width: 60)
                            Toggle("", isOn: bit(\.inband, b.id)).labelsHidden().frame(width: 60)
                        }.padding(.vertical, 3)
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }.padding(.horizontal, 10)
            }
            Divider()
            HStack {
                Spacer()
                Button { accept(draft.value) } label: { Label("Accept", systemImage: "checkmark") }.keyboardShortcut(.defaultAction)
                Button { cancel() } label: { Label("Cancel", systemImage: "xmark") }.keyboardShortcut(.cancelAction)
            }.padding(10)
        }
        .frame(width: 320, height: 470)
    }
}

/// Bands configuration, like the Windows app: every band's name and frequency span in MHz.
struct BandSettingsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text("Band name:").fontWeight(.bold)
                    Text("Frequency span (MHz):").fontWeight(.bold).gridCellColumns(2)
                }
                ForEach(model.bands.indices, id: \.self) { i in
                    let none = model.bands[i].id == 0
                    GridRow {
                        Text(none ? "" : "\(model.bands[i].id)").frame(width: 22, alignment: .trailing)
                        TextField("", text: $model.bands[i].name).frame(width: 120)
                        TextField("", text: $model.bands[i].freqStart).frame(width: 110)
                        TextField("", text: $model.bands[i].freqStop).frame(width: 110)
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(none).opacity(none ? 0.5 : 1)
                }
            }
            .padding(12)
        }
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
            Divider().padding(.vertical, 4)
            HStack {
                Button("Back up settings…") { BackupFile.save(client.makeBackup()) }
                Button("Restore from backup…") {
                    guard let b = BackupFile.open() else { return }
                    model.restoreFrom = b
                    model.confirmRestore = true
                }
            }
            Text("A backup holds the device name, antennas, bands, output relays and FlexRadio ports. Network and stacking settings are not included.")
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
        .confirmationDialog("Restore settings from this backup?", isPresented: $model.confirmRestore, titleVisibility: .visible) {
            Button("Restore") {
                if let b = model.restoreFrom { client.restore(b) }
                model.restoreFrom = nil
                close()   // the open edits are now stale
            }
            Button("Cancel", role: .cancel) { model.restoreFrom = nil }
        } message: { Text(restoreMessage) }
    }
}

extension AdvancedPage {
    private var restoreMessage: String {
        guard let b = model.restoreFrom else { return "" }
        var text = "Saved \(b.created.formatted(date: .abbreviated, time: .shortened))"
        if !b.name.isEmpty { text += " from “\(b.name)”" }
        text += ". Antenna, band, output relay and FlexRadio settings that differ will be overwritten. Unsaved edits in this window are discarded."
        if !b.serial.isEmpty, let s = client.connectedDevice?.serial, s != b.serial {
            text += "\n\nThis backup is from a different unit (serial \(b.serial))."
        }
        return text
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

/// The radio's frequency from Hamlib rigctld or flrig, turned into the port's band by this app.
struct CatPage: View {
    @EnvironmentObject var client: AGClient
    @EnvironmentObject var catManager: CatManager
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("For radios without a FlexRadio link or band data cable: the app reads the frequency from rigctld or flrig and sets the port's band (the source becomes MANUAL). A band change waits while the radio transmits, so antennas never switch under power. Works while this app is running.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(1...max(client.ports.count, 1), id: \.self) { portBox($0) }
            }.padding(8)
        }
    }

    private func binding(_ id: Int) -> Binding<CatConfig> {
        Binding(get: { model.cat[id] ?? CatConfig() }, set: { model.cat[id] = $0 })
    }

    private func portBox(_ id: Int) -> some View {
        let c = binding(id)
        return GroupBox("Radio \(id == 1 ? "A" : "B")") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Frequency from", selection: Binding(get: { c.wrappedValue.kind }, set: { k in
                    // Swap to the other program's usual port unless a custom one was typed.
                    if CatConfig.Kind.allCases.map(\.defaultPort).contains(c.wrappedValue.port) { c.wrappedValue.port = k.defaultPort }
                    c.wrappedValue.kind = k
                })) {
                    ForEach(CatConfig.Kind.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).frame(width: 360)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Address")
                        TextField("127.0.0.1", text: c.host).textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                    GridRow {
                        Text("Port")
                        TextField("", value: c.port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                }
                .disabled(c.wrappedValue.kind == .off).opacity(c.wrappedValue.kind == .off ? 0.5 : 1)
                statusLine(id)
            }.padding(4)
        }
    }

    /// Live state of the saved link (edits take effect on Save).
    @ViewBuilder private func statusLine(_ id: Int) -> some View {
        if catManager.isActive(port: id) {
            if let s = catManager.status[id] {
                if let e = s.error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if let hz = s.hz {
                    let band = s.band.flatMap { b in client.bands.first { $0.id == b }?.name } ?? "no configured band"
                    Label(String(format: "%.3f MHz → %@%@", Double(hz) / 1e6, band, s.heldForTX ? " (waiting for TX to end)" : ""),
                          systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                }
            } else {
                Label("Connecting…", systemImage: "hourglass").foregroundStyle(.secondary)
            }
        }
    }
}

/// FlexRadio integration, one box per radio port, like the Windows app.
struct FlexPage: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(1...max(client.ports.count, 1), id: \.self) { port in
                    portBox(port)
                }
            }.padding(8)
        }
    }

    /// Radios the unit can see, plus the configured serial if that radio isn't answering right now.
    private func choices(_ serial: String) -> [(serial: String, label: String)] {
        var list = client.flexRadios.map { r -> (serial: String, label: String) in
            let who = [r.nickname, r.callsign].filter { !$0.isEmpty }.joined(separator: " · ")
            return (r.serial, who.isEmpty ? r.serial : "\(r.serial) — \(who)")
        }
        if !serial.isEmpty, !list.contains(where: { $0.serial == serial }) { list.append((serial, serial)) }
        return list
    }

    private func portBox(_ port: Int) -> some View {
        let cfg = Binding(get: { model.flex[port] ?? FlexPortConfig() }, set: { model.flex[port] = $0 })
        return VStack(spacing: 0) {
            Text("FlexRadio Integration - Port \(port == 1 ? "A" : "B")")
                .foregroundStyle(.white).fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(red: 0.0, green: 0.50, blue: 0.10))
            VStack(alignment: .leading, spacing: 10) {
                Text("Serial number:").fontWeight(.bold)
                Picker("", selection: cfg.serial) {
                    Text("").tag("")
                    ForEach(choices(cfg.wrappedValue.serial), id: \.serial) { Text($0.label).tag($0.serial) }
                }.labelsHidden().frame(maxWidth: .infinity)
                HStack(spacing: 20) {
                    HStack {
                        Text("Antenna:").fontWeight(.bold)
                        Picker("", selection: cfg.ant) {
                            ForEach(["ANT1", "ANT2", "XVRT"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 95)
                    }
                    HStack {
                        Text("PTT:").fontWeight(.bold)
                        Picker("", selection: cfg.ptt) {
                            ForEach(["LAN", "RCA"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 85)
                    }
                    Spacer()
                }
            }
            .padding(10)
        }
        .overlay(Rectangle().stroke(Theme.edge, lineWidth: Theme.lineWidth))
    }
}

