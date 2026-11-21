import XCTest
@testable import AntennaGenius

final class PasswordPolicyTests: XCTestCase {
    func testRules() {
        XCTAssertTrue(PasswordPolicy.isAcceptable("Tr0ub4dor&3x"))
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0ub4dor&3"), "11 characters")
        XCTAssertFalse(PasswordPolicy.isAcceptable("tr0ub4dor&3x"), "no upper case")
        XCTAssertFalse(PasswordPolicy.isAcceptable("TR0UB4DOR&3X"), "no lower case")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Troubador&xyz"), "no digit")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0ub4dor33x"), "no symbol")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0ub4dor &3x"), "space")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0ub4dor|3xY"), "| would end the command")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0ub4dor=3xY"), "= would break key=value")
        XCTAssertFalse(PasswordPolicy.isAcceptable("Tr0ub4dör&3xY"), "non-ASCII")
        XCTAssertFalse(PasswordPolicy.isAcceptable(""))
    }

    func testEveryRuleIsReported() {
        let unmet = PasswordPolicy.requirements("abc").filter { !$0.met }.map(\.label)
        XCTAssertEqual(unmet.count, 4, "length, upper case, digit, symbol: \(unmet)")
    }

    func testStrengthLevels() {
        XCTAssertEqual(PasswordPolicy.strength(""), .weak)
        XCTAssertEqual(PasswordPolicy.strength("short1A!"), .weak, "fails the rules")
        XCTAssertEqual(PasswordPolicy.strength("Password123!"), .weak, "common word")
        XCTAssertEqual(PasswordPolicy.strength("aaaaaaaaaA1!"), .weak, "mostly repeats")
        XCTAssertEqual(PasswordPolicy.strength("Tr0ub4dor&3x"), .medium, "12 characters")
        XCTAssertEqual(PasswordPolicy.strength("Tr0ub4dor&3xKq"), .strong, "14 characters")
        XCTAssertEqual(PasswordPolicy.strength("Tr0ub4dor&3xKq!vZ"), .veryStrong, "17 characters")
    }
}
