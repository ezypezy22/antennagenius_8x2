import XCTest
@testable import AntennaGenius

final class ParsingTests: XCTestCase {
    func testPrologue() {
        guard case .prologue(let v, let auth) = AGProtocol.parse(line: "V4.1.19 AG") else { return XCTFail("not a prologue") }
        XCTAssertEqual(v, "4.1.19")
        XCTAssertFalse(auth)
        guard case .prologue(_, let wan) = AGProtocol.parse(line: "V4.1.19 AG AUTH") else { return XCTFail("not a prologue") }
        XCTAssertTrue(wan)
    }

    func testResponse() {
        guard case .response(let r) = AGProtocol.parse(line: "R9|20|") else { return XCTFail("not a response") }
        XCTAssertEqual(r.seq, 9)
        XCTAssertEqual(r.code, 0x20)
        XCTAssertFalse(r.ok)
        guard case .response(let ok) = AGProtocol.parse(line: "R12|0|flex 1 serial= ant=ANT2 ptt=LAN") else { return XCTFail("not a response") }
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.message, "flex 1 serial= ant=ANT2 ptt=LAN")
    }

    func testStatus() {
        guard case .status(let m) = AGProtocol.parse(line: "S0|relay tx=00 rx=00 state=00") else { return XCTFail("not a status") }
        XCTAssertEqual(m, "relay tx=00 rx=00 state=00")
    }

    func testGarbageIsUnknown() {
        guard case .unknown = AGProtocol.parse(line: "hello") else { return XCTFail("should be unknown") }
        guard case .unknown = AGProtocol.parse(line: "Rxx|0|") else { return XCTFail("should be unknown") }
    }

    func testTokens() {
        let (w, kv) = AGProtocol.tokens("port 1 auto=0 source=FLEX band=7 nickname=")
        XCTAssertEqual(w, ["port", "1"])
        XCTAssertEqual(kv["source"], "FLEX")
        XCTAssertEqual(kv["band"], "7")
        XCTAssertEqual(kv["nickname"], "")
    }
}

final class ModelTests: XCTestCase {
    func testPortStatus() {
        var p = PortState(id: 1)
        p.apply(AGProtocol.tokens("port 1 auto=0 source=MANUAL band=7 rxant=3 txant=3 tx=1 inhibit=0").kv)
        XCTAssertEqual(p.source, "MANUAL")
        XCTAssertEqual(p.band, 7)
        XCTAssertEqual(p.rxant, 3)
        XCTAssertEqual(p.txant, 3)
        XCTAssertTrue(p.tx)
        XCTAssertFalse(p.inhibit)
    }

    func testBeaconUsesRealSourceAddress() {
        let beacon = "AG ip=6.6.6.6 port=9007 v=4.1.19 serial=88-52-AE name=Antenna_Genius ports=2 antennas=8 mode=master uptime=1"
        XCTAssertEqual(DiscoveredDevice(beacon: beacon, sourceIP: "10.43.10.59")?.ip, "10.43.10.59")
        XCTAssertEqual(DiscoveredDevice(beacon: beacon)?.ip, "6.6.6.6")
        XCTAssertEqual(DiscoveredDevice(beacon: beacon)?.name, "Antenna Genius")
        XCTAssertNil(DiscoveredDevice(beacon: "not a beacon"))
    }

    func testOutputGroupAndOutput() {
        let g = OutputGroup(line: "group 2 in_use=1 name=My_Group mode=BAND bands=3 allow_none=1")
        XCTAssertEqual(g?.id, 2)
        XCTAssertEqual(g?.mode, "BAND")
        XCTAssertEqual(g?.bands, 3)
        XCTAssertEqual(g?.allowNone, true)
        XCTAssertEqual(g?.name, "My Group")
        let o = OutputDef(line: "output 4 in_use=1 group=2 name=Amp state=0A hotkey=0 trx=1")
        XCTAssertEqual(o?.id, 4)
        XCTAssertEqual(o?.group, 2)
        XCTAssertEqual(o?.state, 0x0A)
        XCTAssertEqual(o?.trx, true)
    }

    func testFlexAndStack() {
        let f = FlexPortConfig(kv: AGProtocol.tokens("flex 1 serial=0921-1104-6600-2953 ant=ANT2 ptt=LAN").kv)
        XCTAssertEqual(f.serial, "0921-1104-6600-2953")
        XCTAssertEqual(f.ant, "ANT2")
        XCTAssertEqual(f.ptt, "LAN")
        let s = StackConfig(kv: AGProtocol.tokens("stack in_use=1 serial=9A-3A-DC mode=1").kv)
        XCTAssertTrue(s.inUse)
        XCTAssertEqual(s.serial, "9A-3A-DC")
        XCTAssertEqual(s.mode, 1)
    }
}

final class ValidationTests: XCTestCase {
    func testIPv4() {
        XCTAssertTrue(NetworkConfig.validIPv4("10.43.10.59"))
        XCTAssertTrue(NetworkConfig.validIPv4("0.0.0.0"))
        XCTAssertFalse(NetworkConfig.validIPv4("10.43.10"))
        XCTAssertFalse(NetworkConfig.validIPv4("256.1.1.1"))
        XCTAssertFalse(NetworkConfig.validIPv4("a.b.c.d"))
        XCTAssertFalse(NetworkConfig.validIPv4("10.43.10.59 extra"))
    }

    func testSafeToken() {
        XCTAssertTrue(NetworkConfig.isSafeToken("abc123"))
        XCTAssertFalse(NetworkConfig.isSafeToken("a b"))
        XCTAssertFalse(NetworkConfig.isSafeToken("a\nb"))
        XCTAssertFalse(NetworkConfig.isSafeToken("a|b"))
    }
}

@MainActor
final class ClientTextTests: XCTestCase {
    func testWireCannotInjectCommands() {
        let c = AGClient()
        XCTAssertEqual(c.wire("My Antenna"), "My_Antenna")
        let evil = c.wire("x\r\nC1|reboot")
        XCTAssertFalse(evil.contains("\n") || evil.contains("\r") || evil.contains("|"))
        XCTAssertEqual(c.wire("a=b|c"), "a_b_c")
        XCTAssertEqual(c.wire("  hi  "), "hi")
    }

    func testPasswordIsMasked() {
        XCTAssertEqual(AGClient.masked("network set dhcp=1 auth=Secret123"), "network set dhcp=1 auth=***")
        XCTAssertEqual(AGClient.masked("port set 1 rxant=2"), "port set 1 rxant=2")
    }

    func testAutoReconnectOnlyWhenAllowed() {
        let c = AGClient()
        let dev = DiscoveredDevice(beacon: "AG ip=10.43.10.59 port=9007 v=4.1.19 serial=88-52-AE name=X ports=2 antennas=8 mode=master uptime=1")!
        c.autoConnect = false
        c.autoReconnect(discovered: [dev])
        XCTAssertEqual(c.state, .disconnected, "must not reconnect after a deliberate disconnect")
        XCTAssertNil(c.lastDevice)
    }
}
