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

    func testLateLanderIsQuarantined() {
        let filter = PalmFilter()
        XCTAssertNotNil(filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.5, phase: .began)])))
        // 16 pt of recent travel: the finger is established and moving.
        for i in 1...4 {
            let x = 0.5 + Double(i) * 4.0 / 400.0
            XCTAssertNotNil(filter.process(frame(Double(i) * 0.01,
                                                 [.init(id: 1, x: x, y: 0.5, phase: .moved)])))
        }
        let out = filter.process(frame(0.05, [
            .init(id: 1, x: 0.54, y: 0.5, phase: .stationary),
            .init(id: 2, x: 0.5, y: 0.6, phase: .began),
        ]))
        XCTAssertEqual(out?.touches.map(\.id), [1],
                       "a touch landing during finger motion is a suspect")
        XCTAssertEqual(filter.state(of: 2), .pending)
    }

    func testLanderAfterMotionStopsIsFinger() {
        let filter = PalmFilter()
        XCTAssertNotNil(filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.5, phase: .began)])))
        for i in 1...4 {
            let x = 0.5 + Double(i) * 4.0 / 400.0
            _ = filter.process(frame(Double(i) * 0.01,
                                     [.init(id: 1, x: x, y: 0.5, phase: .moved)]))
        }
        // Motion stops; recency window (0.15 s) expires.
        _ = filter.process(frame(0.30, [.init(id: 1, x: 0.54, y: 0.5, phase: .stationary)]))
        let out = filter.process(frame(0.31, [
            .init(id: 1, x: 0.54, y: 0.5, phase: .stationary),
            .init(id: 2, x: 0.5, y: 0.6, phase: .began),
        ]))
        XCTAssertEqual(out?.touches.count, 2, "a lander after motion settles is a finger")
        XCTAssertEqual(filter.state(of: 2), .finger)
    }

    func testBandDefinitiveWhenPromotionDisabled() {
        let filter = PalmFilter()
        filter.config.promotionTravel = nil
        XCTAssertNil(filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.1, phase: .began)])))
        XCTAssertEqual(filter.state(of: 1), .palm)
        // Even deliberate monotonic travel cannot promote.
        for i in 1...6 {
            let x = 0.5 + Double(i) * 5.0 / 400.0
            XCTAssertNil(filter.process(frame(Double(i) * 0.01,
                                              [.init(id: 1, x: x, y: 0.1, phase: .moved)])))
        }
        XCTAssertEqual(filter.state(of: 1), .palm)
    }

    func testPhantomTouchForgottenWhenAbsentFromFrame() {
        let filter = PalmFilter()
        XCTAssertNil(filter.process(frame(0, [.init(id: 1, x: 0.5, y: 0.1, phase: .began)])))
        XCTAssertEqual(filter.state(of: 1), .pending)
        // Id 1's ended is never delivered (the host stopped receiving
        // events); the next frame doesn't carry it, so it is forgotten.
        let out = filter.process(frame(1.0, [.init(id: 2, x: 0.5, y: 0.5, phase: .began)]))
        XCTAssertEqual(out?.touches.count, 1)
        XCTAssertNil(filter.state(of: 1))
        // A host reusing the id starts fresh instead of inheriting the
        // phantom's classification.
        let reused = filter.process(frame(1.1, [
            .init(id: 2, x: 0.5, y: 0.5, phase: .stationary),
            .init(id: 1, x: 0.5, y: 0.5, phase: .began),
        ]))
        XCTAssertEqual(reused?.touches.count, 2)
        XCTAssertEqual(filter.state(of: 1), .finger)
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

    /// A palm patch left over from before the episode enters mid-life
    /// (unknown id, no began sample) inside the band. Position-based
    /// admission suppresses it and the swipe recovers its true count -
    /// this fixture regressed to [3: 1] when unknown ids defaulted to
    /// finger.
    func testLeftoverPalmPatchSuppressed() throws {
        let file = FixtureSupport.palmFixturesDir.appendingPathComponent("palm-swipe-leftover-patch.jsonl")
        let filtered = try FixtureSupport.replay(file, palmFiltered: true)
        XCTAssertEqual(beganCounts(filtered), [2: 1])
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
        XCTAssertGreaterThanOrEqual(correct, 17, "filtered 2-finger swipes")
        XCTAssertLessThanOrEqual(wrong, 3, "filtered wrong-count swipes")
    }

    /// Second palm session, recorded after the band rule shipped.
    /// Unfiltered, the palm noise nearly kills recognition outright
    /// (1 swipe in ~10 s). The residual wrong counts are palm patches
    /// born mid-pad during quiet gaps between swipes - the mode no
    /// birth-time rule can catch (docs/palm-rejection.md).
    func testPalmSessionTwoAggregate() throws {
        let file = FixtureSupport.palmFixturesDir.appendingPathComponent("palm-session-2.jsonl")
        let unfiltered = try FixtureSupport.replay(file, palmFiltered: false)
        XCTAssertLessThanOrEqual(beganCounts(unfiltered).values.reduce(0, +), 1,
                                 "unfiltered, palm noise suppresses recognition almost entirely")
        let filtered = try FixtureSupport.replay(file, palmFiltered: true)
        let counts = beganCounts(filtered)
        XCTAssertGreaterThanOrEqual(counts[2, default: 0], 10, "filtered 2-finger swipes")
        XCTAssertLessThanOrEqual(counts.filter { $0.key != 2 }.values.reduce(0, +), 5,
                                 "filtered wrong-count swipes")
    }
}
