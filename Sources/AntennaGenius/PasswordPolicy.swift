import Foundation

/// Rules for a new remote access password, and a strength estimate for the meter in Settings › Network.
/// Logging in is not held to these rules, so a unit whose password was set elsewhere can still be reached.
enum PasswordPolicy {
    static let minLength = 12

    enum Strength: Int, CaseIterable {
        case weak = 1, medium, strong, veryStrong
        var label: String {
            switch self {
            case .weak: return "Weak"
            case .medium: return "Medium"
            case .strong: return "Strong"
            case .veryStrong: return "Very strong"
            }
        }
    }

    struct Requirement: Identifiable {
        let label: String
        let met: Bool
        var id: String { label }
    }

    /// Printable ASCII only, without `|` and `=`, which the device's `key=value` command syntax can't carry.
    /// (Other characters may not survive the device's firmware, which doesn't document what it accepts.)
    static func isAllowed(_ c: Character) -> Bool {
        guard let a = c.asciiValue else { return false }
        return (0x21...0x7E).contains(a) && c != "|" && c != "="
    }

    private static func isSymbol(_ c: Character) -> Bool { isAllowed(c) && !c.isLetter && !c.isNumber }

    static func requirements(_ s: String) -> [Requirement] {
        [Requirement(label: "At least \(minLength) characters", met: s.count >= minLength),
         Requirement(label: "An upper-case letter (A–Z)", met: s.contains { $0.isASCII && $0.isUppercase }),
         Requirement(label: "A lower-case letter (a–z)", met: s.contains { $0.isASCII && $0.isLowercase }),
         Requirement(label: "A digit (0–9)", met: s.contains { $0.isASCII && $0.isNumber }),
         Requirement(label: "A symbol, e.g. ! # $ % & * ? @", met: s.contains(where: isSymbol)),
         Requirement(label: "No spaces, accented letters, | or =", met: s.allSatisfy(isAllowed))]
    }

    static func isAcceptable(_ s: String) -> Bool { requirements(s).allSatisfy(\.met) }

    /// Words a guesser tries first; containing one counts as weak whatever else is there.
    private static let common = ["password", "passw0rd", "qwerty", "123456", "abcdef", "letmein",
                                 "welcome", "admin", "antenna", "genius", "iloveyou", "monkey", "dragon"]

    /// Weak until every rule is met. After that, estimated guessing effort (length × character-set size,
    /// halved when most characters repeat) sets the level: a minimal 12–13 character password is Medium,
    /// 14–16 Strong, 17 or more Very strong.
    static func strength(_ s: String) -> Strength {
        guard isAcceptable(s) else { return .weak }
        let lower = s.lowercased()
        if common.contains(where: lower.contains) { return .weak }
        var bits = Double(s.count) * log2(92)   // 26 + 26 + 10 + 30 allowed symbols
        if Set(s).count * 2 < s.count { bits /= 2 }
        switch bits {
        case ..<60: return .weak
        case ..<85: return .medium
        case ..<105: return .strong
        default: return .veryStrong
        }
    }
}
