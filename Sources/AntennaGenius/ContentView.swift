import SwiftUI

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var discovery: Discovery
    @EnvironmentObject var client: AGClient
    @StateObject private var showAbout = Box(false)
    @StateObject private var chosenFor = Box<String?>(nil)   // serial of the unit the port choice was made for
    @AppStorage("appearance") private var appearance = Appearance.light.rawValue
    @AppStorage("portMode") private var portMode = PortMode.so2r.rawValue

    var body: some View {
        let _ = Appearance.apply(appearance)
        Group {
            if client.state == .connected && client.connectedDevice?.serial != chosenFor.value {
                PortChooser(mode: $portMode, showAbout: showAbout, done: { chosenFor.value = client.connectedDevice?.serial })
            } else if client.state == .connected {
                PanelView(showAbout: showAbout, portMode: $portMode, reselect: { chosenFor.value = nil })
            } else {
                ConnectView()
            }
        }
        .frame(width: client.state == .connected ? Theme.fs(230) : 320)
        .background(Theme.window)
        .preferredColorScheme(appearance == Appearance.light.rawValue ? .light : .dark)
        .id(appearance)   // rebuild so every view re-reads the theme
        .sheet(isPresented: $showAbout.value) { AboutView(close: { showAbout.value = false }) }
    }
}

// MARK: - Title bar

/// Gear menu shared by the panel and the port chooser. `reselect` is nil on the chooser itself.
struct TitleBar: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var showAbout: Box<Bool>
    let reselect: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance") private var appearance = Appearance.light.rawValue
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("checkForUpdates") private var checkForUpdates = true

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Menu {
                Button("Settings…") { openWindow(id: "settings") }
                if let reselect { Button("Port chooser…", action: reselect) }
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Button("Protocol log…") { openWindow(id: "log") }
                Toggle("Show in menu bar", isOn: $showMenuBar)
                Divider()
                Button("About Antenna Genius…") { showAbout.value = true }
                Button("Check for Updates…") { Task { await UpdateChecker.shared.check(userInitiated: true) } }
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                Divider()
                // A deliberate disconnect starts the next session at the chooser; a dropped link does not.
                Button("Disconnect") { reselect?(); client.autoConnect = false; client.disconnect() }
                Button("Quit Antenna Genius") { AppDelegate.quit() }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape.fill").foregroundStyle(.gray)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .font(.system(size: Theme.fs(13), weight: .bold))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Theme.chrome.opacity(0.7))
    }
}

// MARK: - Port chooser

/// Which radio port(s) this window controls, like the Windows utility's "Port chooser".
/// A view filter only; the device always keeps both ports.
enum PortMode: String, CaseIterable, Identifiable {
    case a, so2r, b
    var id: String { rawValue }
    var label: String { self == .a ? "Port A" : self == .b ? "Port B" : "SO2R" }
    func shows(_ port: Int) -> Bool { self == .so2r || (self == .a ? port == 1 : port == 2) }
}

struct PortChooser: View {
    @Binding var mode: String
    @ObservedObject var showAbout: Box<Bool>
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(showAbout: showAbout, reselect: nil)
            chooser
        }
    }

    private var chooser: some View {
        VStack(spacing: 10) {
            Text("Port chooser").font(.headline)
            HStack(spacing: 6) {
                ForEach(PortMode.allCases) { m in
                    Button { mode = m.rawValue; done() } label: {
                        Text(m.label).font(.system(size: Theme.fs(13), weight: .semibold))
                            .foregroundStyle(m.rawValue == mode ? Theme.onSelected : Theme.text)
                            .frame(maxWidth: .infinity, minHeight: 70)
                            .background(m.rawValue == mode ? Theme.radioB : Theme.button, in: RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.edge, lineWidth: Theme.lineWidth))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}

// MARK: - Connect screen

struct ConnectView: View {
    @EnvironmentObject var discovery: Discovery
    @EnvironmentObject var client: AGClient
    @AppStorage("appearance") private var appearance = Appearance.light.rawValue
    @AppStorage("lastIP") private var lastIP = ""
    @StateObject private var waited = Box(false)
    @StateObject private var typedIP = Box("")
    @StateObject private var typedError = Box<String?>(nil)
    @StateObject private var password = Box("")

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Menu {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                    }.pickerStyle(.inline)
                } label: { Image(systemName: "circle.lefthalf.filled") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Appearance")
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
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.edge, lineWidth: Theme.lineWidth))
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
                if client.autoConnect, client.lastDevice != nil {
                    Text("Trying to reconnect…").font(.caption).foregroundStyle(.secondary)
                }
            default: EmptyView()
            }
            if let d = client.passwordNeeded { passwordPrompt(d) }
            if let err = discovery.error {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if discovery.devices.isEmpty && waited.value { fallback }
        }
        .padding(20)
        .frame(minHeight: 180)
        .onChange(of: discovery.devices) { _, d in client.autoReconnect(discovered: d) }
        .onAppear {
            client.autoReconnect(discovered: discovery.devices)
            if typedIP.value.isEmpty { typedIP.value = lastIP }
        }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            waited.value = true
        }
        .task {
            // Keep trying every few seconds, e.g. while the unit reboots.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                client.autoReconnect(discovered: discovery.devices)
            }
        }
    }

    /// Asked for when a unit reached over the internet wants its remote access password (saved in the Keychain).
    private func passwordPrompt(_ d: DiscoveredDevice) -> some View {
        VStack(spacing: 8) {
            Divider()
            Text("Remote access password for \(d.name)").font(.caption.weight(.semibold))
            SecureField("Password", text: $password.value)
                .textFieldStyle(.roundedBorder).onSubmit(submitPassword)
            HStack {
                Button("Cancel") { password.value = ""; client.cancelPasswordPrompt() }
                Button("Log in", action: submitPassword).keyboardShortcut(.defaultAction)
                    .disabled(password.value.isEmpty)
            }.controlSize(.small)
            if !NetworkConfig.isSafeToken(password.value) {
                Text("The password can't contain spaces, control characters or \"|\".").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func submitPassword() {
        let pw = password.value
        guard !pw.isEmpty, NetworkConfig.isSafeToken(pw) else { return }
        password.value = ""
        client.submitPassword(pw)
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
                TextField("Device IP or host name", text: $typedIP.value)
                    .textFieldStyle(.roundedBorder).onSubmit(connectTyped)
                Button("Connect", action: connectTyped).disabled(typedIP.value.isEmpty)
            }
            if let e = typedError.value { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func connectTyped() {
        let ip = typedIP.value.trimmingCharacters(in: .whitespaces)
        guard NetworkConfig.validHost(ip) else {
            typedError.value = "Enter an IPv4 address like 10.43.10.59, or a host name like ag.example.net."
            return
        }
        typedError.value = nil
        guard let d = DiscoveredDevice(beacon: "AG ip=\(ip) port=9007 serial=manual-\(ip) name=\(ip)") else { return }
        connect(d)
    }

    private func connect(_ d: DiscoveredDevice) {
        lastIP = d.ip
        client.autoConnect = true
        client.connect(to: d)
    }
}

