import XCTest
@testable import AntennaGenius

@MainActor
final class BackupTests: XCTestCase {
    private func sample() -> DeviceBackup {
        var b = DeviceBackup()
        b.name = "Shack AG"
        b.antennas = [AntennaInfo(id: 1, name: "Yagi", tx: 0x0F, rx: 0xFF, inband: 0)]
        b.bands = [BandInfo(id: 0, name: "None"), BandInfo(id: 5, name: "20m", freqStart: "14.000000", freqStop: "14.350000")]
        var g = OutputGroup(id: 1); g.inUse = true; g.mode = "BAND"; g.bands = 0x20
        b.groups = [g]
        b.flex = ["1": FlexPortConfig()]
        return b
    }

    func testRoundTrip() throws {
        let b = sample()
        let back = try BackupFile.decode(BackupFile.encode(b))
        XCTAssertEqual(back.antennas, b.antennas)
        XCTAssertEqual(back.bands, b.bands)
        XCTAssertEqual(back.groups, b.groups)
        XCTAssertEqual(back.flex, b.flex)
        XCTAssertNil(back.problem())
    }

    func testRejectsBadFields() {
        var b = sample()
        b.flex["1"]?.serial = "x\nreboot"
        XCTAssertNotNil(b.problem())
        b = sample(); b.groups[0].mode = "EVIL"
        XCTAssertNotNil(b.problem())
        b = sample(); b.bands[1].freqStop = "13"
        XCTAssertNotNil(b.problem())
        b = sample(); b.format = 2
        XCTAssertNotNil(b.problem())
    }

    func testNotJSONFails() {
        XCTAssertThrowsError(try BackupFile.decode(Data("hello".utf8)))
    }
}
