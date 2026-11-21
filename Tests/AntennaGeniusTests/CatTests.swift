import XCTest
@testable import AntennaGenius

final class CatTests: XCTestCase {
    private let bands = [
        BandInfo(id: 0, name: "None", freqStart: "0.000000", freqStop: "0.000000"),
        BandInfo(id: 1, name: "160", freqStart: "1.800000", freqStop: "2.000000"),
        BandInfo(id: 5, name: "20", freqStart: "14.000000", freqStop: "14.350000"),
        BandInfo(id: 4, name: "30", freqStart: "10.100000", freqStop: "10.150000"),
        BandInfo(id: 9, name: "6", freqStart: "50.000000", freqStop: "54.000000"),
    ]

    func testFrequencyToBand() {
        XCTAssertEqual(CatBand.band(forHz: 14_074_000, in: bands), 5)
        XCTAssertEqual(CatBand.band(forHz: 14_000_000, in: bands), 5, "lower edge counts")
        XCTAssertEqual(CatBand.band(forHz: 14_350_000, in: bands), 5, "upper edge counts")
        XCTAssertEqual(CatBand.band(forHz: 10_136_000, in: bands), 4)
        XCTAssertEqual(CatBand.band(forHz: 1_840_000, in: bands), 1)
        XCTAssertEqual(CatBand.band(forHz: 7_074_000, in: bands), 0, "no configured band: None")
        XCTAssertEqual(CatBand.band(forHz: 0, in: bands), 0, "band 0's empty range never matches")
    }

    func testWhatToSend() {
        var p = PortState(id: 1)
        p.source = "AUTO"; p.auto = true; p.band = 0
        XCTAssertEqual(CatBand.bandToSend(target: 5, port: p), 5)
        p.source = "MANUAL"; p.auto = false; p.band = 5
        XCTAssertNil(CatBand.bandToSend(target: 5, port: p), "already there")
        p.source = "FLEX"
        XCTAssertEqual(CatBand.bandToSend(target: 5, port: p), 5, "band right but source isn't MANUAL")
        p.source = "MANUAL"; p.tx = true
        XCTAssertNil(CatBand.bandToSend(target: 9, port: p), "never switch while transmitting")
        p.tx = false
        XCTAssertEqual(CatBand.bandToSend(target: 9, port: p), 9, "sent once TX ends")
    }

    func testRigctldReplies() {
        XCTAssertEqual(CatBand.parseRigctld("14074000\n"), 14_074_000)
        XCTAssertEqual(CatBand.parseRigctld("14074000.000000"), 14_074_000)
        XCTAssertNil(CatBand.parseRigctld("RPRT -11"))
        XCTAssertNil(CatBand.parseRigctld(""))
    }

    func testFlrigReplies() {
        let plain = #"<?xml version="1.0"?><methodResponse><params><param><value>14074000</value></param></params></methodResponse>"#
        XCTAssertEqual(CatBand.parseFlrig(plain), 14_074_000)
        let string = "<methodResponse><params><param>\n<value><string>7074000</string></value></param></params></methodResponse>"
        XCTAssertEqual(CatBand.parseFlrig(string), 7_074_000)
        let fault = "<methodResponse><fault><value><struct><member><name>faultCode</name><value><i4>1</i4></value></member></struct></value></fault></methodResponse>"
        XCTAssertNil(CatBand.parseFlrig(fault))
    }

    func testConfigRoundTrip() {
        let c = CatConfig(kind: .flrig, host: "shack-mac.local", port: 12345)
        let back = try? JSONDecoder().decode(CatConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }
}
