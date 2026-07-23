import XCTest
import TrackpadKit

/// Replays every fixture in `fixtures/` through a fresh recognizer and
/// asserts the recognized outcome. A fixture without an expectation
/// entry fails the suite, so the table can't silently fall behind the
/// fixture set.
final class ReplayFixtureTests: XCTestCase {
    struct Expected {
        var kind: GestureEvent.Kind?
        var direction: GestureEvent.Direction = .none
        var fingers: Int = 0
        var endMagnitude: ClosedRange<Double>?

        static func swipe(_ direction: GestureEvent.Direction, fingers: Int) -> Expected {
            Expected(kind: .swipe, direction: direction, fingers: fingers)
        }

        static func pinch(scale: Double) -> Expected {
            Expected(kind: .pinch, fingers: 2,
                     endMagnitude: (scale - 0.05)...(scale + 0.05))
        }

        static let nothing = Expected(kind: nil)
    }

    static let expectations: [String: Expected] = [
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

    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures")
    }

    func testAllFixtures() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no fixtures found at \(Self.fixturesDir.path)")

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard let expected = Self.expectations[name] else {
                XCTFail("fixture \(name) has no expectation entry")
                continue
            }
            try assertFixture(file, name: name, expected: expected)
        }
    }

    private func assertFixture(_ file: URL, name: String, expected: Expected) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        let (frames, malformed) = TouchStreamReplay.parse(text)
        XCTAssertTrue(malformed.isEmpty, "\(name): malformed lines \(malformed)")
        XCTAssertFalse(frames.isEmpty, "\(name): no frames")

        let recognizer = TrackpadGestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0) }
        TouchStreamReplay.run(frames: frames, recognizer: recognizer)

        guard let kind = expected.kind else {
            XCTAssertTrue(events.isEmpty,
                          "\(name): expected no gestures, got \(events.map(\.phase))")
            return
        }

        XCTAssertEqual(events.filter { $0.phase == .began }.count, 1, "\(name): began count")
        XCTAssertEqual(events.filter { $0.phase == .ended }.count, 1, "\(name): ended count")
        XCTAssertTrue(events.allSatisfy { $0.phase != .cancelled }, "\(name): unexpected cancel")
        XCTAssertTrue(events.allSatisfy { $0.kind == kind }, "\(name): kind")
        XCTAssertTrue(events.allSatisfy { $0.direction == expected.direction },
                      "\(name): direction")
        XCTAssertTrue(events.allSatisfy { $0.fingerCount == expected.fingers },
                      "\(name): fingers")

        guard let ended = events.last, ended.phase == .ended else {
            XCTFail("\(name): last event should be ended")
            return
        }
        if let range = expected.endMagnitude {
            XCTAssertTrue(range.contains(ended.magnitude),
                          "\(name): end magnitude \(ended.magnitude) not in \(range)")
        } else if kind == .swipe {
            XCTAssertGreaterThan(ended.magnitude, 30, "\(name): swipe magnitude")
        }
    }
}
