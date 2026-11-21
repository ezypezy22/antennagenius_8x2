import XCTest
@testable import AntennaGenius

@MainActor
final class UpdateTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(UpdateChecker.isNewer("26.11.10", than: "26.11.9"))
        XCTAssertTrue(UpdateChecker.isNewer("26.12.1", than: "26.11.2"))
        XCTAssertFalse(UpdateChecker.isNewer("26.11.2", than: "26.11.2"))
        XCTAssertFalse(UpdateChecker.isNewer("26.10.13", than: "26.11.1"))
        XCTAssertTrue(UpdateChecker.isNewer("26.11.2", than: "dev"))
    }

    func testVersionFromTagOrAsset() {
        XCTAssertEqual(UpdateChecker.version(in: ["26.11.1"]), "26.11.1")
        XCTAssertEqual(UpdateChecker.version(in: ["public", "AntennaGenius-26.11.2-macos-arm64.dmg"]), "26.11.2")
        XCTAssertNil(UpdateChecker.version(in: ["public", "notes.txt"]))
    }

    /// Shaped like the real list: the newest build sits under a `public` tag, and drafts and prereleases don't count.
    func testNewestRelease() {
        let json = """
        [{"tag_name":"26.11.1","draft":false,"prerelease":false,"html_url":"https://example.com/a",
          "assets":[{"name":"AntennaGenius-26.11.1-macos-arm64.dmg"}]},
         {"tag_name":"public","draft":false,"prerelease":false,"html_url":"https://example.com/b",
          "assets":[{"name":"AntennaGenius-26.11.2-macos-arm64.dmg"}]},
         {"tag_name":"27.1.1","draft":false,"prerelease":true,"html_url":"https://example.com/c","assets":[]},
         {"tag_name":"27.1.2","draft":true,"prerelease":false,"html_url":"https://example.com/d","assets":[]}]
        """
        XCTAssertEqual(UpdateChecker.newest(in: Data(json.utf8)),
                       UpdateChecker.Release(version: "26.11.2", page: URL(string: "https://example.com/b")!))
        XCTAssertNil(UpdateChecker.newest(in: Data("{}".utf8)))
    }
}
