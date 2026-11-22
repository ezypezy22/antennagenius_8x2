import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ActivityWindowRoot: View {
    @AppStorage("appearance") private var appearance = Appearance.light.rawValue
    var body: some View {
        let _ = Appearance.apply(appearance)
        ActivityView()
            .background(Theme.window)
            .preferredColorScheme(appearance == Appearance.light.rawValue ? .light : .dark)
            .id(appearance)
    }
}

struct ActivityView: View {
    @StateObject private var tab = Box("history")
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab.value) {
                Text("History").tag("history")
                Text("Usage").tag("usage")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 220).padding(10)
            Divider()
            if tab.value == "history" { HistoryPane() } else { UsagePane() }
        }
        .frame(minWidth: 620, minHeight: 380)
    }
}

/// Radio filter shared by both panes: nil = both.
private struct RadioPicker: View {
    @Binding var radio: Int
    var body: some View {
        Picker("Radio", selection: $radio) {
            Text("Both").tag(0); Text("Radio A").tag(1); Text("Radio B").tag(2)
        }.fixedSize()
    }
}

struct HistoryPane: View {
    @ObservedObject var store = ActivityStore.shared
    @StateObject private var radio = Box(0)
    @StateObject private var confirmClear = Box(false)

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .medium; return f
    }()

    private var rows: [HistoryEntry] {
        store.history.reversed().filter { radio.value == 0 || $0.radio == nil || $0.radio == radio.value }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RadioPicker(radio: $radio.value)
                Spacer()
                Button("Export CSV…", action: export).disabled(store.history.isEmpty)
                Button("Clear…") { confirmClear.value = true }.disabled(store.history.isEmpty)
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Table(rows) {
                TableColumn("Time") { Text(Self.time.string(from: $0.at)).monospacedDigit() }.width(min: 130, ideal: 150)
                TableColumn("Radio") { Text($0.radio.map { $0 == 1 ? "A" : "B" } ?? "—") }.width(44)
                TableColumn("Change") { e in
                    Text(e.text).foregroundStyle(e.kind == .message || e.kind == .cat ? Color.orange : Theme.text)
                }
                TableColumn("By") { Text($0.origin ?? "Elsewhere").foregroundStyle(.secondary) }.width(min: 90, ideal: 130)
            }
            Text("“Elsewhere” is a change this app didn't ask for: FlexRadio, another client or the unit's front panel. Keeps the last \(ActivityStore.historyLimit) entries.")
                .font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmClear.value) {
            Button("Clear", role: .destructive) { store.clearHistory() }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Antenna Genius history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.csv().write(to: url, atomically: true, encoding: .utf8)
    }
}

struct UsagePane: View {
    @EnvironmentObject var client: AGClient
    @ObservedObject var store = ActivityStore.shared
    @StateObject private var radio = Box(0)
    @StateObject private var period = Box(UsagePeriod.week)
    @StateObject private var confirmReset = Box(false)

    var body: some View {
        let u = store.totals(serial: client.connectedDevice?.serial, radio: radio.value == 0 ? nil : radio.value, period: period.value)
        VStack(spacing: 0) {
            HStack {
                RadioPicker(radio: $radio.value)
                Picker("Period", selection: $period.value) {
                    ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                Spacer()
                Button("Reset…") { confirmReset.value = true }
            }.padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    UsageList(title: "Bands", items: u.bands)
                    UsageList(title: "Antennas", items: u.antennas)
                }.padding(10)
            }
            Text("Time counts while this app is connected. Transmit time comes from the unit's TX flag (the radio keyed on that port); the Antenna Genius has no power or SWR sensors.")
                .font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Reset all usage figures?", isPresented: $confirmReset.value) {
            Button("Reset", role: .destructive) { store.resetUsage() }
        }
    }
}

struct UsageList: View {
    let title: String
    let items: [String: UsageCounter]

    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        if m < 1 { return s < 1 ? "0m" : "<1m" }
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }

    /// Most used first; equal times (e.g. both radios counted the same seconds) by name, so rows don't
    /// swap places each time the window redraws.
    static func ordered(_ items: [String: UsageCounter]) -> [(key: String, value: UsageCounter)] {
        items.sorted {
            $0.value.on != $1.value.on ? $0.value.on > $1.value.on : $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }
    }

    var body: some View {
        let sorted = Self.ordered(items)
        let top = max(sorted.first?.value.on ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if sorted.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
            ForEach(sorted, id: \.key) { name, c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(name).lineLimit(1)
                        Spacer()
                        Text(Self.duration(c.on)).monospacedDigit()
                        Text("TX \(Self.duration(c.tx))").monospacedDigit().foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18))
                            Capsule().fill(Theme.radioB).frame(width: g.size.width * c.on / top)
                            Capsule().fill(Theme.transmit).frame(width: g.size.width * c.tx / top)
                        }
                    }.frame(height: 6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name): \(Self.duration(c.on)) in use, \(Self.duration(c.tx)) transmitting")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
