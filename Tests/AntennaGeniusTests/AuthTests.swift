import XCTest
@testable import AntennaGenius

/// Plays the device's side of the remote access login by feeding the client the lines a unit would send.
/// Everything runs synchronously, before the (never serviced) connection could change state.
@MainActor
final class AuthTests: XCTestCase {
    private let serial = "test-auth-\(UUID().uuidString)"
    private let client = AGClient()
    override func tearDown() { client.disconnect(); Keychain.deletePassword(for: serial) }

    private func device(_ line: String) { client.ingest(Data((line + "\r\n").utf8)) }

    /// Sequence number of the last `auth` command the client sent, from the protocol log.
    private func lastAuthSeq() -> Int? {
        guard let l = client.logStore.lines.last(where: { $0.text.contains("|auth ") })?.text,
              let r = l.range(of: #"C(\d+)\|"#, options: .regularExpression) else { return nil }
        return Int(l[r].dropFirst().dropLast())
    }

    func testLoginAsksThenRejectsThenAccepts() throws {
        let dev = DiscoveredDevice(beacon: "AG ip=192.0.2.1 port=9007 serial=\(serial) name=Remote ports=2 antennas=8")!

        // No saved password: the client stops and asks, without sending a login or reconnecting by itself.
        client.connect(to: dev)
        device("V4.1.19 AG AUTH")
        XCTAssertEqual(client.passwordNeeded, dev)
        XCTAssertNil(lastAuthSeq())
        XCTAssertFalse(client.autoConnect)
        if case .failed = client.state {} else { XCTFail("expected failed, got \(client.state)") }

        // Wrong password: refused, forgotten, asked again, with no extra error banner.
        client.submitPassword("nope")
        XCTAssertNil(client.passwordNeeded)
        device("V4.1.19 AG AUTH")
        let first = try XCTUnwrap(lastAuthSeq())
        device("R\(first)|FF|")
        XCTAssertEqual(client.passwordNeeded, dev)
        XCTAssertNil(Keychain.password(for: serial))
        XCTAssertNil(client.lastError)

        // Right password: the session starts, the password is kept and never shown in the log.
        client.submitPassword("s3cret")
        device("V4.1.19 AG AUTH")
        let second = try XCTUnwrap(lastAuthSeq())
        XCTAssertNotEqual(client.state, .connected, "nothing starts before the login is accepted")
        device("R\(second)|0|")
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(Keychain.password(for: serial), "s3cret")
        XCTAssertTrue(client.logStore.lines.contains { $0.text.contains("auth code=***") })
        XCTAssertFalse(client.logStore.lines.contains { $0.text.contains("s3cret") })
        XCTAssertTrue(client.logStore.lines.contains { $0.text.contains("|sub port all") }, "bootstrap ran")
    }

    func testLANGreetingStartsWithoutLogin() {
        let dev = DiscoveredDevice(beacon: "AG ip=192.0.2.1 port=9007 serial=\(serial) name=Local ports=2 antennas=8")!
        client.connect(to: dev)
        device("V4.1.19 AG")
        XCTAssertEqual(client.state, .connected)
        XCTAssertNil(lastAuthSeq())
        XCTAssertNil(client.passwordNeeded)
    }
}
