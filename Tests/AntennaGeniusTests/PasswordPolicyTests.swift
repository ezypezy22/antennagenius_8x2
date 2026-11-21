import XCTest
@testable import AntennaGenius

final class PasswordPolicyTests: XCTestCase {
    func testRules() {
        XCTAssertTrue(PasswordPolicy.isAcceptable("Tr0b4d&x"))
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0b4d&"), "7 characters")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0b4d&xy"), "9 characters: the device refuses it")
        XCTAssertFalse(PasswordPolicy.isAcceptable("tr0b4d&x"), "no upper case")
        XCTAssertFalse(PasswordPolicy.isAcceptable("TR0B4D&X"), "no lower case")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Trobad&x"), "no digit")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0b4d3x"), "no symbol")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0 4d&x"), "space")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0b4d|x"), "| would end the command")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0b4d=x"), "= would break key=value")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0b4ö&x"), "non-ASCII")
        XCTAssertFalse(PasswordPolicy.isAcceptable(""))
        XCTAssertFalse(PasswordPolicy.isAcceptable("Admin1!x"), "common word")
        XCTAssertFalse(PasswordPolicy.isAcceptable("aaaaaA1!"), "mostly repeats")
    }

    func testEveryRuleIsReported() {
        let unmet = PasswordPolicy.requirements("abc").filter { !$0.met }.map(\.label)
        XCTAssertEqual(unmet.count, 4, "length, upper case, digit, symbol: \(unmet)")
    }

    func testStrengthLevels() {
        XCTAssertEqual(PasswordPolicy.strength(""), .weak)
        XCTAssertEqual(PasswordPolicy.strength("Ab1!c"), .weak, "under 6")
        XCTAssertEqual(PasswordPolicy.strength("Admin1!x"), .weak, "common word")
        XCTAssertEqual(PasswordPolicy.strength("aaaaaA1!"), .weak, "mostly repeats")
        XCTAssertEqual(PasswordPolicy.strength("Tr0b4d&xy"), .weak, "too long for the device")
        XCTAssertEqual(PasswordPolicy.strength("Tr0b4&x"), .medium, "7 characters")
        XCTAssertEqual(PasswordPolicy.strength("trobad3x"), .medium, "8, two types")
        XCTAssertEqual(PasswordPolicy.strength("Trobad3x"), .strong, "8, three types")
        XCTAssertEqual(PasswordPolicy.strength("Tr0b4d&x"), .veryStrong, "8, all four types")
    }
}

final class NetworkPasswordTests: XCTestCase {
    /// `network get` answers `auth=1`, not the password: it must never be loaded as a password to send back.
    func testReportedAuthIsOnlyAFlag() {
        let set = NetworkConfig(kv: AGProtocol.tokens("network dhcp=0 address=10.43.10.222 netmask=255.255.255.0 gateway=10.43.10.1 auth=1").kv)
        XCTAssertTrue(set.passwordSet)
        XCTAssertEqual(set.auth, "", "nothing to resend")
        XCTAssertFalse(NetworkConfig(kv: ["auth": "0"]).passwordSet)
        XCTAssertFalse(NetworkConfig(kv: [:]).passwordSet)
    }
}
