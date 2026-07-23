import XCTest
import TrackpadKit

/// The PalmFilter state machine on synthetic frames, plus regression
/// against real palm-planted recordings carved into `fixtures/palm/`.
final class PalmFilterTests: XCTestCase {

    // MARK: Synthetic state-machine tests

    private func frame(_ t: TimeInterval, _ touches: [TouchSample]) -> TouchFrame {
        TouchFrame(t: t, w: 400, h: 240, touches: touches)
    }

    func testTouchBornInBandIsSuppressed() {
        let filter = PalmFilter()
        let out = filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.1, phase: .began)]))
        XCTAssertNil(out)
        XCTAssertEqual(filter.state(of: 1), .pending)
        XCTAssertNil(filter.process(frame(0.01, [.init(id: 1, x: 0.5, y: 0.1, phase: .stationary)])))
    }

    func testTouchBornAboveBandPasses() {
        let filter = PalmFilter()
        let out = filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.5, phase: .began)]))
        XCTAssertEqual(out?.touches.count, 1)
        XCTAssertEqual(filter.state(of: 1), .finger)
    }

    func testMonotonicMotionPromotesWithSyntheticBegan() {
        let filter = PalmFilter()
        XCTAssertNil(filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.1, phase: .began)])))
        // 5 device pt per step along x (x is normalized over w=400).
        var promoted: TouchFrame?
        for i in 1...6 {
            let x = 0.5 + Double(i) * 5.0 / 400.0
            promoted = filter.process(frame(Double(i) * 0.01,
                                            [.init(id: 1, x: x, y: 0.1, phase: .moved)]))
            if promoted != nil { break }
        }
        XCTAssertEqual(filter.state(of: 1), .finger)
        XCTAssertEqual(promoted?.touches.first?.phase, .began,
                       "promotion should enter the stream as a fresh landing")
    }

    func testJitterDoesNotPromote() {
        let filter = PalmFilter()
        XCTAssertNil(filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.1, phase: .began)])))
        // Alternating +8/-8 pt: large bounding box, heavy reverse accumulation.
        var x = 0.5
        for i in 1...20 {
            x += (i.isMultiple(of: 2) ? -8.0 : 8.0) / 400.0
            XCTAssertNil(filter.process(frame(Double(i) * 0.01,
                                              [.init(id: 1, x: x, y: 0.1, phase: .moved)])),
                         "jittering suspect must stay suppressed")
        }
        XCTAssertEqual(filter.state(of: 1), .pending)
    }

    func testStationaryAgingMakesPalmSticky() {
        let filter = PalmFilter()
        XCTAssertNil(filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.1, phase: .began)])))
        XCTAssertNil(filter.process(frame(2.5, [.init(id: 1, x: 0.5, y: 0.1, phase: .stationary)])))
        XCTAssertEqual(filter.state(of: 1), .palm)
        // A late monotonic smear must no longer promote.
        for i in 1...6 {
            let x = 0.5 + Double(i) * 5.0 / 400.0
            XCTAssertNil(filter.process(frame(2.5 + Double(i) * 0.01,
                                              [.init(id: 1, x: x, y: 0.1, phase: .moved)])))
        }
        XCTAssertEqual(filter.state(of: 1), .palm)
    }

    func testSuppressedTouchEndsSilently() {
        let filter = PalmFilter()
        XCTAssertNil(filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.1, phase: .began)])))
        XCTAssertNil(filter.process(frame(0.1, [.init(id: 1, x: 0.5, y: 0.1, phase: .ended)])))
        XCTAssertNil(filter.state(of: 1))
    }

    // MARK: Synthetic and clean fixtures are unaffected

    /// The filter must not change the outcome of any fixture in the
    /// main set - including the graze fixtures, whose transient contact
    /// is born inside the band and simply gets suppressed instead of
    /// being handled by the recognizer's re-settle.
    func testCleanFixturesKeepTheirOutcomes() throws {
        let files = try FixtureSupport.jsonlFiles(in: FixtureSupport.fixturesDir)
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard let expected = ReplayFixtureTests.expectations[name] else { continue }
            let events = try FixtureSupport.replay(file, palmFiltered: true)
            FixtureSupport.assertOutcome(events, name: "\(name)+filter", expected: expected)
        }
    }

    // MARK: Real palm recordings

    private func beganCounts(_ events: [GestureEvent]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for e in events where e.phase == .began {
            counts[e.fingerCount, default: 0] += 1
        }
        return counts
    }

    func testPalmSwipeRecoversTwoFingers() throws {
        let file = FixtureSupport.palmFixturesDir.appendingPathComponent("palm-swipe-2f.jsonl")
        let unfiltered = try FixtureSupport.replay(file, palmFiltered: false)
        XCTAssertEqual(beganCounts(unfiltered), [3: 1],
                       "unfiltered, the palm inflates the count to 3")
        let filtered = try FixtureSupport.replay(file, palmFiltered: true)
        XCTAssertEqual(beganCounts(filtered), [2: 1])
        XCTAssertTrue(filtered.allSatisfy { $0.kind == .swipe && $0.direction == .left })
    }

    /// Known limitation, pinned: a long-lived palm contact born just
    /// above the band still inflates the count. When an above-band
    /// heuristic lands (docs/palm-rejection.md), this expectation
    /// flips to [2: 1].
    func testPalmAboveBandStillInflates() throws {
        let file = FixtureSupport.palmFixturesDir.appendingPathComponent("palm-swipe-above-band.jsonl")
        let filtered = try FixtureSupport.replay(file, palmFiltered: true)
        XCTAssertEqual(beganCounts(filtered), [3: 1])
    }

    func testPalmLowNoiseSwipeUnharmed() throws {
        let file = FixtureSupport.palmFixturesDir.appendingPathComponent("palm-swipe-low-noise.jsonl")
        let filtered = try FixtureSupport.replay(file, palmFiltered: true)
        XCTAssertEqual(beganCounts(filtered), [2: 1])
        XCTAssertTrue(filtered.allSatisfy { $0.kind == .swipe && $0.direction == .right })
    }

    /// 17 seconds of continuous palm-planted swiping. Bounds rather
    /// than exact counts, so threshold tuning can improve results
    /// without churning this test; a regression below the floor fails.
    func testPalmSessionAggregate() throws {
        let file = FixtureSupport.palmFixturesDir.appendingPathComponent("palm-session.jsonl")
        let unfiltered = try FixtureSupport.replay(file, palmFiltered: false)
        XCTAssertEqual(beganCounts(unfiltered)[2, default: 0], 0,
                       "unfiltered, not a single palm-planted swipe locks 2 fingers")
        let filtered = try FixtureSupport.replay(file, palmFiltered: true)
        let counts = beganCounts(filtered)
        let correct = counts[2, default: 0]
        let wrong = counts.filter { $0.key != 2 }.values.reduce(0, +)
        XCTAssertGreaterThanOrEqual(correct, 15, "filtered 2-finger swipes")
        XCTAssertLessThanOrEqual(wrong, 5, "filtered wrong-count swipes")
    }
}
