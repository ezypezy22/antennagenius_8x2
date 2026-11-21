import SwiftUI

// MARK: - Band source pinout pages (information only, like the Windows app)

/// The device's 15-pin VGA-style connector as seen looking at it: pins 5-1 across the top, 10-6 in the middle,
/// 15-11 along the bottom. Callouts draw a labelled box and a line to each pin that is used.
struct ConnectorDiagram: View {
    struct Callout { let pin: Int; let label: String; let at: CGPoint }
    let callouts: [Callout]
    /// Blank space to trim from the top when no callouts sit above the connector.
    var cropTop: CGFloat = 0

    private static let w: CGFloat = 470, h: CGFloat = 230
    /// Pin centre in the diagram's own coordinates.
    static func position(of pin: Int) -> CGPoint {
        let cx: CGFloat = 235, dx: CGFloat = 30
        switch pin {
        case 1...5:  return CGPoint(x: cx + CGFloat(3 - pin) * dx, y: 98)
        case 6...10: return CGPoint(x: cx - 15 + CGFloat(8 - pin) * dx, y: 123)
        default:     return CGPoint(x: cx + CGFloat(13 - pin) * dx, y: 148)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                // Connector shell and mounting holes
                var shell = Path()
                shell.addRoundedRect(in: CGRect(x: 125, y: 76, width: 220, height: 94), cornerSize: CGSize(width: 10, height: 10))
                ctx.stroke(shell, with: .color(Theme.text), lineWidth: 2)
                for x in [100.0, 370.0] {
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - 11, y: 112, width: 22, height: 22)), with: .color(Theme.text), lineWidth: 2)
                }
                var d = Path()   // the D-shaped plug
                d.move(to: CGPoint(x: 150, y: 84)); d.addLine(to: CGPoint(x: 320, y: 84))
                d.addLine(to: CGPoint(x: 308, y: 162)); d.addLine(to: CGPoint(x: 162, y: 162)); d.closeSubpath()
                ctx.stroke(d, with: .color(Theme.text), lineWidth: 1.5)
                // Pins
                let used = Set(callouts.map(\.pin))
                for pin in 1...15 {
                    let c = Self.position(of: pin)
                    let r = CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)
                    ctx.fill(Path(ellipseIn: r), with: .color(used.contains(pin) ? Color.accentColor.opacity(0.35) : Theme.window))
                    ctx.stroke(Path(ellipseIn: r), with: .color(Theme.text), lineWidth: used.contains(pin) ? 2 : 1)
                }
                // Leader lines
                for c in callouts {
                    var l = Path(); l.move(to: Self.position(of: c.pin)); l.addLine(to: c.at)
                    ctx.stroke(l, with: .color(Theme.text.opacity(0.7)), lineWidth: 1)
                }
            }
            ForEach(1...15, id: \.self) { pin in
                Text("\(pin)").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text)
                    .position(Self.position(of: pin))
            }
            ForEach(callouts.indices, id: \.self) { i in
                Text(callouts[i].label).font(.system(size: 11)).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.white).overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                    .position(callouts[i].at)
            }
        }
        .frame(width: Self.w, height: Self.h)
        .offset(y: -cropTop)
        .frame(width: Self.w, height: Self.h - cropTop, alignment: .topLeading)
        .clipped()
    }
}

struct BCDPage: View {
    /// (band, MHz as printed in the manual, HEX code) — Band A..D are the four low bits of the code, H = 1.
    private let bands: [(name: String, mhz: String, code: Int)] = [
        ("160M", "1.8", 1), ("80M", "3.5", 2), ("40M", "7", 3), ("30M", "10", 4), ("20M", "14", 5),
        ("17M", "18", 6), ("15M", "21", 7), ("12M", "24", 8), ("10M", "28", 9), ("6M", "50", 10), ("None", "", 0)
    ]
    private func level(_ code: Int, _ bit: Int) -> String { code & (1 << bit) != 0 ? "H" : "L" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("This is the pinout when looking at the device connector:").font(.callout)
                // Pins 15 (GND), 14 (Band D), 13 (Band C), 12 (Band B), 11 (Band A) along the bottom row.
                ConnectorDiagram(callouts: [
                    .init(pin: 15, label: "GND", at: CGPoint(x: 115, y: 208)),
                    .init(pin: 14, label: "Band D", at: CGPoint(x: 185, y: 208)),
                    .init(pin: 13, label: "Band C", at: CGPoint(x: 255, y: 208)),
                    .init(pin: 12, label: "Band B", at: CGPoint(x: 325, y: 208)),
                    .init(pin: 11, label: "Band A", at: CGPoint(x: 395, y: 208)),
                ], cropTop: 60).frame(maxWidth: .infinity)
                Text("This is the BCD data table:").font(.callout)
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Text("Band").bold().frame(width: 70, alignment: .leading)
                        ForEach(bands, id: \.name) { Text($0.name).bold().frame(width: 40) }
                    }
                    GridRow {
                        Text("Frequency").frame(width: 70, alignment: .leading)
                        ForEach(bands, id: \.name) { Text($0.mhz).frame(width: 40) }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal).gridCellColumns(12)
                    ForEach([("Band A", 0), ("Band B", 1), ("Band C", 2), ("Band D", 3)], id: \.0) { row in
                        GridRow {
                            Text(row.0).frame(width: 70, alignment: .leading)
                            ForEach(bands, id: \.name) { Text(level($0.code, row.1)).fontWeight(.semibold).frame(width: 40) }
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal).gridCellColumns(12)
                    GridRow {
                        Text("HEX code").frame(width: 70, alignment: .leading)
                        ForEach(bands, id: \.name) { Text(String($0.code, radix: 16, uppercase: true)).frame(width: 40) }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                Text("It is not possible to select the 60M band through BCD. Pin numbers are as printed in the 4O3A Antenna Genius user manual.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
}

struct P2PPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("This is the pinout when looking at the device connector:").font(.callout)
                // Pin n selects Antenna n (1-8); pin 15 is GND.
                ConnectorDiagram(callouts: [
                    .init(pin: 5, label: "Antenna 5", at: CGPoint(x: 95, y: 25)),
                    .init(pin: 4, label: "Antenna 4", at: CGPoint(x: 170, y: 25)),
                    .init(pin: 3, label: "Antenna 3", at: CGPoint(x: 245, y: 25)),
                    .init(pin: 2, label: "Antenna 2", at: CGPoint(x: 320, y: 25)),
                    .init(pin: 1, label: "Antenna 1", at: CGPoint(x: 395, y: 25)),
                    .init(pin: 6, label: "Antenna 6", at: CGPoint(x: 420, y: 75)),
                    .init(pin: 7, label: "Antenna 7", at: CGPoint(x: 420, y: 118)),
                    .init(pin: 8, label: "Antenna 8", at: CGPoint(x: 420, y: 161)),
                    .init(pin: 15, label: "GND", at: CGPoint(x: 125, y: 208)),
                ]).frame(maxWidth: .infinity)
                Text("Applying +12 V to a pin selects that antenna for the port, regardless of band. Pin numbers are as printed in the 4O3A Antenna Genius user manual.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
}

