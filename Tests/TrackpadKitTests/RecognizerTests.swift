import XCTest
import TrackpadKit

/// The recognizer's unhappy paths on synthetic frames: cancellation by
/// an added finger, the awaitingLift drain, stale-frame abandonment,
/// and fling velocity semantics at lift.
final class RecognizerTests: XCTestCase {

    private func frame(_ t: TimeInterval, _ touches: [TouchSample]) -> TouchFrame {
        TouchFrame(t: t, w: 400, h: 240, touches: touches)
    }

    /// Lands two fingers at y 0.5 and swipes them right until the swipe
    /// commits (4 device pt per 10 ms frame at w = 400). Returns the
    /// time of the last fed frame; the fingers end at x 0.35 / 0.45.
    private func commitSwipe(_ recognizer: TrackpadGestureRecognizer) -> TimeInterval {
        var t = 0.0
        var x1 = 0.30, x2 = 0.40
        recognizer.process(frame(t, [
            .init(id: 1, x: x1, y: 0.5, phase: .began),
            .init(id: 2, x: x2, y: 0.5, phase: .began),
        ]))
        for _ in 0..<5 {
            t += 0.01
            x1 += 0.01
            x2 += 0.01
            recognizer.process(frame(t, [
                .init(id: 1, x: x1, y: 0.5, phase: .moved),
                .init(id: 2, x: x2, y: 0.5, phase: .moved),
            ]))
        }
        return t
    }

    func testAddedFingerCancelsAndDrains() {
        let recognizer = TrackpadGestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0) }
        var t = commitSwipe(recognizer)
        XCTAssertEqual(events.first?.phase, .began)
        XCTAssertEqual(events.first?.direction, .right)

        t += 0.01
        recognizer.process(frame(t, [
            .init(id: 1, x: 0.35, y: 0.5, phase: .stationary),
            .init(id: 2, x: 0.45, y: 0.5, phase: .stationary),
            .init(id: 3, x: 0.50, y: 0.7, phase: .began),
        ]))
        XCTAssertEqual(events.last?.phase, .cancelled)
        XCTAssertEqual(recognizer.state, .awaitingLift)

        // Draining: nothing more is emitted, even for motion, until the
        // pad is empty.
        let countAfterCancel = events.count
        t += 0.01
        recognizer.process(frame(t, [
            .init(id: 1, x: 0.38, y: 0.5, phase: .moved),
            .init(id: 2, x: 0.48, y: 0.5, phase: .moved),
            .init(id: 3, x: 0.50, y: 0.7, phase: .ended),
        ]))
        XCTAssertEqual(recognizer.state, .awaitingLift)
        t += 0.01
        recognizer.process(frame(t, [
            .init(id: 1, x: 0.38, y: 0.5, phase: .ended),
            .init(id: 2, x: 0.48, y: 0.5, phase: .ended),
        ]))
        XCTAssertEqual(recognizer.state, .idle)
        XCTAssertEqual(events.count, countAfterCancel)
    }

    func testStaleFrameTimeoutCancelsCommitted() {
        let recognizer = TrackpadGestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0) }
        let t = commitSwipe(recognizer)

        recognizer.tick(now: t + 0.2)
        XCTAssertNotEqual(recognizer.state, .idle,
                          "within the timeout the sequence stays alive")
        recognizer.tick(now: t + 0.5)
        XCTAssertEqual(events.last?.phase, .cancelled)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testLiftAfterPauseFlingsAtZero() {
        let recognizer = TrackpadGestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0) }
        var t = commitSwipe(recognizer)

        // Hold still (frames keep arriving) well past the velocity window.
        for _ in 0..<20 {
            t += 0.01
            recognizer.process(frame(t, [
                .init(id: 1, x: 0.35, y: 0.5, phase: .stationary),
                .init(id: 2, x: 0.45, y: 0.5, phase: .stationary),
            ]))
        }
        t += 0.01
        recognizer.process(frame(t, [
            .init(id: 1, x: 0.35, y: 0.5, phase: .ended),
            .init(id: 2, x: 0.45, y: 0.5, phase: .ended),
        ]))
        XCTAssertEqual(events.last?.phase, .ended)
        XCTAssertEqual(events.last?.velocity, 0)
    }

    func testFlickLiftFlingsPositive() {
        let recognizer = TrackpadGestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0) }
        var t = commitSwipe(recognizer)

        // Lift right out of the 400 pt/s motion.
        t += 0.01
        recognizer.process(frame(t, [
            .init(id: 1, x: 0.35, y: 0.5, phase: .ended),
            .init(id: 2, x: 0.45, y: 0.5, phase: .ended),
        ]))
        XCTAssertEqual(events.last?.phase, .ended)
        XCTAssertGreaterThan(events.last?.velocity ?? 0, 100)
    }
}
