import XCTest
@testable import AntennaGenius

@MainActor
final class ActivityTests: XCTestCase {
    private let antName = { (id: Int) in ["", "Yagi", "Vertical", "Beverage"][id] }

    func testUsageCountsSelectionAndTransmit() {
        var d = UsageDay()
        var p = PortState(id: 1)
        p.band = 5; p.rxant = 3; p.txant = 1
        d.add(10, port: p, band: "20m", antenna: antName)
        p.tx = true
        d.add(5, port: p, band: "20m", antenna: antName)
        XCTAssertEqual(d.bands["20m"], UsageCounter(on: 15, tx: 5))
        XCTAssertEqual(d.antennas["Yagi"], UsageCounter(on: 15, tx: 5), "TX antenna")
        XCTAssertEqual(d.antennas["Beverage"], UsageCounter(on: 15, tx: 0), "RX-only antenna never counts TX")
        p.rxant = 1; p.tx = false
        d.add(4, port: p, band: "20m", antenna: antName)
        XCTAssertEqual(d.antennas["Yagi"]?.on, 19, "same antenna for RX and TX counts once")
        p.rxant = 0; p.txant = 0
        d.add(3, port: p, band: "None", antenna: antName)
        XCTAssertEqual(d.antennas.count, 2, "no antenna, nothing counted")
        XCTAssertEqual(d.bands["None"]?.on, 3)
    }

    func testTotalsByRadioAndPeriod() {
        let s = ActivityStore(directory: nil)
        let now = Date()
        let today = ActivityStore.dayKey(now)
        let old = ActivityStore.dayKey(Calendar.current.date(byAdding: .day, value: -10, to: now)!)
        s.usage = ["SN1": [today: ["1": UsageDay(bands: ["20m": UsageCounter(on: 60, tx: 6)]),
                                   "2": UsageDay(bands: ["40m": UsageCounter(on: 30, tx: 0)])],
                           old: ["1": UsageDay(bands: ["20m": UsageCounter(on: 100, tx: 10)])]],
                   "SN2": [today: ["1": UsageDay(bands: ["20m": UsageCounter(on: 1000, tx: 0)])]]]
        XCTAssertEqual(s.totals(serial: "SN1", radio: 1, period: .today, now: now).bands["20m"], UsageCounter(on: 60, tx: 6))
        XCTAssertEqual(s.totals(serial: "SN1", radio: 1, period: .month, now: now).bands["20m"], UsageCounter(on: 160, tx: 16))
        XCTAssertEqual(s.totals(serial: "SN1", radio: 1, period: .week, now: now).bands["20m"]?.on, 60, "10 days ago is outside 7 days")
        XCTAssertEqual(s.totals(serial: "SN1", radio: nil, period: .today, now: now).bands.count, 2, "both radios")
        XCTAssertEqual(s.totals(serial: nil, radio: 1, period: .all, now: now).bands["20m"]?.on, 1160, "all units")
    }

    func testChangeWording() {
        var a = PortState(id: 1), b = PortState(id: 1)
        a.rxant = 1; a.txant = 1; a.band = 5; a.source = "FLEX"
        b.rxant = 3; b.txant = 1; b.band = 6; b.source = "MANUAL"
        let band = { (id: Int) in id == 5 ? "20m" : "17m" }
        let d = ActivityStore.describe(old: a, new: b, antenna: antName, band: band).map(\.1)
        XCTAssertEqual(d, ["RX → Beverage, TX → Yagi", "Band → 17m", "Source → MANUAL"])
        b = a; b.rxant = 0; b.txant = 0
        XCTAssertEqual(ActivityStore.describe(old: a, new: b, antenna: antName, band: band).map(\.1), ["Released (no antenna)"])
        b = a; b.tx = true
        XCTAssertTrue(ActivityStore.describe(old: a, new: b, antenna: antName, band: band).isEmpty, "keying alone isn't history")
    }

    func testOriginOfChanges() {
        let c = AGClient()
        c.connect(to: DiscoveredDevice(beacon: "AG ip=192.0.2.1 port=9007 serial=test-origin name=X ports=2 antennas=8")!)
        let feed = { (l: String) in c.ingest(Data((l + "\r\n").utf8)) }
        var seen: [(Int, String?)] = []
        c.portObservers.append { _, new, origin in seen.append((new.rxant, origin)) }
        feed("V4.1.19 AG")
        feed("S0|port 1 auto=0 source=MANUAL band=5 rxant=1 txant=1 tx=0 inhibit=0")
        XCTAssertTrue(seen.isEmpty, "first report after connecting is the baseline")
        feed("S0|port 1 auto=0 source=MANUAL band=5 rxant=2 txant=2 tx=0 inhibit=0")
        c.withOrigin("Preset “Night”") { c.clearAntenna(port: 1) }
        feed("S0|port 1 auto=0 source=MANUAL band=5 rxant=0 txant=0 tx=0 inhibit=0")
        XCTAssertEqual(seen.map(\.0), [2, 0])
        XCTAssertNil(seen[0].1, "nobody here asked: elsewhere")
        XCTAssertEqual(seen[1].1, "Preset “Night”")
        c.disconnect()
    }

    func testEqualTimesKeepAStableOrder() {
        let items = ["None": UsageCounter(on: 600), "40m": UsageCounter(on: 600), "20m": UsageCounter(on: 900)]
        for _ in 0..<20 { XCTAssertEqual(UsageList.ordered(items).map(\.key), ["20m", "40m", "None"]) }
    }

    func testCSV() {
        let s = ActivityStore(directory: nil)
        s.add(1, .antenna, "Antenna → \"Big\" Yagi", origin: nil)
        let lines = s.csv().split(separator: "\n")
        XCTAssertEqual(lines.first, "time,radio,change,by")
        XCTAssertTrue(lines[1].hasSuffix(",A,\"Antenna → \"\"Big\"\" Yagi\",\"Elsewhere\""), String(lines[1]))
    }
}
