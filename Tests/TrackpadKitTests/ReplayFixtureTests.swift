import XCTest
import TrackpadKit

/// Replays every fixture in `fixtures/` through a fresh recognizer and
/// asserts the recognized outcome. A fixture without an expectation
/// entry fails the suite, so the table can't silently fall behind the
/// fixture set.
final class ReplayFixtureTests: XCTestCase {
    static let expectations: [String: FixtureExpectation] = [
        "pinch-in-2f": .pinch(scale: 0.61),
        "pinch-out-2f": .pinch(scale: 1.58),
        "swipe-left-2f-slow-stagger": .swipe(.left, fingers: 2),
        "swipe-left-3f-staggered": .swipe(.left, fingers: 3),
        "swipe-left-3f": .swipe(.left, fingers: 3),
        "swipe-right-2f-early-graze": .swipe(.right, fingers: 2),
        "swipe-right-2f-thumb-graze": .swipe(.right, fingers: 2),
        "swipe-right-4f": .swipe(.right, fingers: 4),
        "swipe-up-2f": .swipe(.up, fingers: 2),
        "tap-2f": .nothing,
        "wander-2f": .nothing,
    ]

    func testAllFixtures() throws {
        let files = try FixtureSupport.jsonlFiles(in: FixtureSupport.fixturesDir)
        XCTAssertFalse(files.isEmpty,
                       "no fixtures found at \(FixtureSupport.fixturesDir.path)")

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard let expected = Self.expectations[name] else {
                XCTFail("fixture \(name) has no expectation entry")
                continue
            }
            let events = try FixtureSupport.replay(file, palmFiltered: false)
            FixtureSupport.assertOutcome(events, name: name, expected: expected)
        }
    }
}
