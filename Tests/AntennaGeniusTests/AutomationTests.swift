import XCTest
@testable import AntennaGenius

@MainActor
final class AutomationTests: XCTestCase {
    private func parse(_ s: String) -> Result<AutomationCommand, AutomationError> { Automation.parse(URL(string: s)!) }

    func testLinks() {
        XCTAssertEqual(try parse("agenius://select?radio=A&antenna=3").get(), .select(port: 1, antenna: .number(3)))
        XCTAssertEqual(try parse("agenius://select?radio=b&antenna=Big%20Yagi").get(), .select(port: 2, antenna: .name("Big Yagi")))
        XCTAssertEqual(try parse("agenius://select?port=2&antenna=1&focus=1").get(), .select(port: 2, antenna: .number(1)))
        XCTAssertEqual(try parse("agenius:select?radio=A&antenna=4").get(), .select(port: 1, antenna: .number(4)))
        XCTAssertEqual(try parse("agenius://release?radio=B").get(), .release(port: 2))
        XCTAssertEqual(try parse("AGENIUS://Preset?name=Contest%2020/40").get(), .preset(name: "Contest 20/40"))
    }

    func testBadLinksExplainThemselves() {
        XCTAssertThrowsError(try parse("agenius://select?antenna=3").get())
        XCTAssertThrowsError(try parse("agenius://select?radio=C&antenna=3").get())
        XCTAssertThrowsError(try parse("agenius://select?radio=A").get())
        XCTAssertThrowsError(try parse("agenius://preset").get())
        XCTAssertThrowsError(try parse("agenius://reboot").get(), "only select, release and preset")
        XCTAssertThrowsError(try parse("https://example.com/select?radio=A&antenna=1").get())
    }

    func testAntennaByNumberOrName() {
        let ants = [AntennaInfo(id: 1, name: "Big Yagi", tx: 0, rx: 0, inband: 0),
                    AntennaInfo(id: 2, name: "Vertical", tx: 0, rx: 0, inband: 0)]
        XCTAssertEqual(Automation.antennaID(.number(2), in: ants), 2)
        XCTAssertNil(Automation.antennaID(.number(9), in: ants))
        XCTAssertEqual(Automation.antennaID(.name("big_yagi"), in: ants), 1, "case, spaces and underscores don't matter")
        XCTAssertNil(Automation.antennaID(.name("Beverage"), in: ants))
    }

    func testPresetLinkRoundTrip() {
        let p = AntennaPreset(name: "Night low bands", radios: [])
        XCTAssertEqual(try Automation.parse(p.url).get(), .preset(name: "Night low bands"))
    }
}

@MainActor
final class PresetTests: XCTestCase {
    func testUniqueNames() {
        let s = PresetStore()
        s.presets = [AntennaPreset(name: "Contest", radios: [])]
        XCTAssertEqual(s.uniqueName("contest"), "contest 2")
        XCTAssertEqual(s.uniqueName("Contest", except: s.presets[0].id), "Contest", "renaming to itself is fine")
        XCTAssertEqual(s.uniqueName("  "), "Preset")
        XCTAssertNotNil(s.preset(named: "CONTEST"))
        s.presets = []
    }

    func testSummary() {
        let ants = [AntennaInfo(id: 1, name: "Yagi", tx: 0, rx: 0, inband: 0),
                    AntennaInfo(id: 2, name: "Beverage", tx: 0, rx: 0, inband: 0)]
        let p = AntennaPreset(name: "x", radios: [.init(port: 2, rx: 2, tx: 1), .init(port: 1, rx: 1, tx: 1)])
        XCTAssertEqual(PresetStore.summary(p, antennas: ants, outputs: []), "A Yagi · B RX Beverage, TX Yagi")
    }

    /// The device plays its part through `ingest`, as in AuthTests: Radio A transmits, so only B is switched.
    func testPresetSkipsTransmittingRadio() {
        let c = AGClient()
        c.connect(to: DiscoveredDevice(beacon: "AG ip=192.0.2.1 port=9007 serial=test-preset name=X ports=2 antennas=8")!)
        let feed = { (l: String) in c.ingest(Data((l + "\r\n").utf8)) }
        feed("V4.1.19 AG")
        feed("S0|port 1 auto=0 source=MANUAL band=5 rxant=1 txant=1 tx=1 inhibit=0")
        feed("S0|port 2 auto=0 source=MANUAL band=5 rxant=1 txant=1 tx=0 inhibit=0")
        c.apply(preset: AntennaPreset(name: "Test", radios: [.init(port: 1, rx: 3, tx: 3), .init(port: 2, rx: 2, tx: 4)]))
        let sent = c.logStore.lines.map(\.text).filter { $0.contains("port set") }
        XCTAssertEqual(sent.count, 1, "\(sent)")
        XCTAssertTrue(sent[0].hasSuffix("|port set 2 rxant=2 txant=4"), sent[0])
        XCTAssertTrue(c.lastError?.contains("Radio A was transmitting") == true, c.lastError ?? "")
        c.disconnect()
    }
}
