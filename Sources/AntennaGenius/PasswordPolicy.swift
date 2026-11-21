import Foundation

/// Rules for a new remote access password, and a strength estimate for the meter in Settings › Network.
/// Logging in is not held to these rules, so a unit whose password was set elsewhere can still be reached.
enum PasswordPolicy {
    /// Firmware 4.1.19 refuses a longer code with 0x20, so the rules ask for exactly this many characters.
    static let length = 8

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
        let t = types(s)
        return [Requirement(label: "Exactly \(length) characters (the device's maximum)", met: s.count == length),
                Requirement(label: "An upper-case letter (A–Z)", met: t.upper),
                Requirement(label: "A lower-case letter (a–z)", met: t.lower),
                Requirement(label: "A digit (0–9)", met: t.digit),
                Requirement(label: "A symbol, e.g. ! # $ % & * ? @", met: t.symbol),
                Requirement(label: "No spaces, accented letters, | or =", met: s.allSatisfy(isAllowed)),
                Requirement(label: "No common words or mostly repeated characters", met: !s.isEmpty && !isGuessable(s))]
    }

    private static func types(_ s: String) -> (upper: Bool, lower: Bool, digit: Bool, symbol: Bool) {
        (s.contains { $0.isASCII && $0.isUppercase }, s.contains { $0.isASCII && $0.isLowercase },
         s.contains { $0.isASCII && $0.isNumber }, s.contains(where: isSymbol))
    }

    static func isAcceptable(_ s: String) -> Bool { requirements(s).allSatisfy(\.met) }

    /// Words a guesser tries first; containing one counts as weak whatever else is there.
    private static let common = ["password", "passw0rd", "qwerty", "123456", "abcdef", "letmein",
                                 "welcome", "admin", "antenna", "genius", "iloveyou", "monkey", "dragon"]

    /// Contains a common word, or half or fewer of its characters are distinct.
    private static func isGuessable(_ s: String) -> Bool {
        let lower = s.lowercased()
        return common.contains(where: lower.contains) || Set(s).count * 2 <= s.count
    }

    /// Fills as the password is typed. With the length capped at 8, the character types decide the top levels:
    /// Weak under 6 characters, when guessable, or with anything the device can't take; Medium at 6–7 characters
    /// or with two types or fewer; Strong at 8 with three types; Very strong at 8 with all four (every acceptable password).
    static func strength(_ s: String) -> Strength {
        if s.count < 6 || s.count > length || !s.allSatisfy(isAllowed) || isGuessable(s) { return .weak }
        let t = types(s)
        let n = [t.upper, t.lower, t.digit, t.symbol].filter { $0 }.count
        if s.count < length || n <= 2 { return .medium }
        return n == 3 ? .strong : .veryStrong
    }
}
