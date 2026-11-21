import SwiftUI

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
                        .frame(width: 14, height: 14).overlay(Circle().stroke(Theme.edge, lineWidth: Theme.lineWidth))
                    Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

