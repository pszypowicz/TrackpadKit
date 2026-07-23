import XCTest
import TrackpadKit

/// Expected replay outcome of a fixture: a single recognized gesture,
/// or nothing.
struct FixtureExpectation {
    var kind: GestureEvent.Kind?
    var direction: GestureEvent.Direction = .none
    var fingers: Int = 0
    var endMagnitude: ClosedRange<Double>?

    static func swipe(_ direction: GestureEvent.Direction, fingers: Int) -> FixtureExpectation {
        FixtureExpectation(kind: .swipe, direction: direction, fingers: fingers)
    }

    static func pinch(scale: Double) -> FixtureExpectation {
        FixtureExpectation(kind: .pinch, fingers: 2,
                           endMagnitude: (scale - 0.05)...(scale + 0.05))
    }

    static let nothing = FixtureExpectation(kind: nil)
}

enum FixtureSupport {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var fixturesDir: URL { repoRoot.appendingPathComponent("fixtures") }
    static var palmFixturesDir: URL { fixturesDir.appendingPathComponent("palm") }

    static func jsonlFiles(in dir: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Replay a fixture through a fresh recognizer (optionally behind a
    /// fresh PalmFilter) and collect the emitted events.
    static func replay(_ file: URL, palmFiltered: Bool) throws -> [GestureEvent] {
        let text = try String(contentsOf: file, encoding: .utf8)
        let (frames, malformed) = TouchStreamReplay.parse(text)
        XCTAssertTrue(malformed.isEmpty,
                      "\(file.lastPathComponent): malformed lines \(malformed)")
        XCTAssertFalse(frames.isEmpty, "\(file.lastPathComponent): no frames")

        let recognizer = TrackpadGestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0) }
        TouchStreamReplay.run(frames: frames, recognizer: recognizer,
                              palmFilter: palmFiltered ? PalmFilter() : nil)
        return events
    }

    static func assertOutcome(_ events: [GestureEvent], name: String,
                              expected: FixtureExpectation,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let kind = expected.kind else {
            XCTAssertTrue(events.isEmpty,
                          "\(name): expected no gestures, got \(events.map(\.phase))",
                          file: file, line: line)
            return
        }

        XCTAssertEqual(events.filter { $0.phase == .began }.count, 1,
                       "\(name): began count", file: file, line: line)
        XCTAssertEqual(events.filter { $0.phase == .ended }.count, 1,
                       "\(name): ended count", file: file, line: line)
        XCTAssertTrue(events.allSatisfy { $0.phase != .cancelled },
                      "\(name): unexpected cancel", file: file, line: line)
        XCTAssertTrue(events.allSatisfy { $0.kind == kind },
                      "\(name): kind", file: file, line: line)
        XCTAssertTrue(events.allSatisfy { $0.direction == expected.direction },
                      "\(name): direction", file: file, line: line)
        XCTAssertTrue(events.allSatisfy { $0.fingerCount == expected.fingers },
                      "\(name): fingers", file: file, line: line)

        guard let ended = events.last, ended.phase == .ended else {
            XCTFail("\(name): last event should be ended", file: file, line: line)
            return
        }
        if let range = expected.endMagnitude {
            XCTAssertTrue(range.contains(ended.magnitude),
                          "\(name): end magnitude \(ended.magnitude) not in \(range)",
                          file: file, line: line)
        } else if kind == .swipe {
            XCTAssertGreaterThan(ended.magnitude, 30, "\(name): swipe magnitude",
                                 file: file, line: line)
        }
    }
}
