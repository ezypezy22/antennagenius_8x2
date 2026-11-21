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

/// Light, dark, or a high-contrast theme (black, bold white, bright yellow / cyan, larger controls) for low vision.
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, highContrast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .highContrast: return "High contrast (low vision)"
        }
    }
    private static var stored: Appearance =
        Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .light
    /// What the theme reads. Each window root calls `apply` from its body, before any child view is built.
    static var current: Appearance { stored }
    static func apply(_ raw: String) { stored = Appearance(rawValue: raw) ?? .light }
}

enum Theme {
    private static var hc: Bool { Appearance.current == .highContrast }

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
    private static func solid(_ c: Color) -> LinearGradient { grad(c, c) }

    /// Text and control sizes scale up in high contrast.
    static var scale: CGFloat { hc ? 1.35 : 1 }
    static func fs(_ v: CGFloat) -> CGFloat { v * scale }
    static var lineWidth: CGFloat { hc ? 2 : 1 }

    static var window: Color { hc ? .black : dyn((0.94, 0.95, 0.96), (0.14, 0.15, 0.17)) }
    static var chrome: Color { hc ? Color(white: 0.12) : dyn((0.85, 0.87, 0.90), (0.20, 0.21, 0.24)) }
    static var text: Color { hc ? .white : dyn((0.08, 0.10, 0.13), (1, 1, 1)) }
    static var onSelected: Color { hc ? .black : .white }
    static var row: LinearGradient {
        hc ? solid(.black) : grad(dyn((0.98, 0.98, 0.99), (0.25, 0.30, 0.36)), dyn((0.86, 0.89, 0.93), (0.18, 0.22, 0.27)))
    }
    static var button: LinearGradient {
        hc ? solid(Color(white: 0.18)) : grad(dyn((1, 1, 1), (0.34, 0.35, 0.38)), dyn((0.85, 0.86, 0.88), (0.16, 0.17, 0.19)))
    }
    /// Per-radio selection colours, as in the Windows panel: A is green, B is blue (yellow and cyan in high contrast).
    static var radioA: LinearGradient {
        hc ? solid(Color(red: 1.0, green: 0.92, blue: 0.0)) : grad(Color(red: 0.10, green: 0.72, blue: 0.20), Color(red: 0.0, green: 0.50, blue: 0.08))
    }
    static var radioB: LinearGradient {
        hc ? solid(Color(red: 0.0, green: 0.85, blue: 1.0)) : grad(Color(red: 0.25, green: 0.60, blue: 1.0), Color(red: 0.05, green: 0.38, blue: 0.85))
    }
    static func selected(port: Int) -> LinearGradient { port == 1 ? radioA : radioB }
    static var transmit: LinearGradient {
        hc ? solid(Color(red: 1.0, green: 0.35, blue: 0.0)) : grad(Color(red: 1.0, green: 0.38, blue: 0.32), Color(red: 0.75, green: 0.12, blue: 0.10))
    }
    static var edge: Color { hc ? .white : dyn((0.62, 0.65, 0.70), (0.0, 0.0, 0.0)) }
}

