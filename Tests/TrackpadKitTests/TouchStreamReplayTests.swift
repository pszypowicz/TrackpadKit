import XCTest
import TrackpadKit

/// The replay harness itself: parse diagnostics and the clock run-out
/// past the final frame.
final class TouchStreamReplayTests: XCTestCase {

    func testMalformedLineNumbersSurviveBlankLines() {
        let text = """
        {"t":0,"w":400,"h":240,"touches":[]}

        not json
        """
        let (frames, malformed) = TouchStreamReplay.parse(text)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(malformed, [3])
    }

    /// A committed swipe whose lift was never recorded: the replay clock
    /// runs one stale-frame timeout past the final frame, so the
    /// recognizer abandons the sequence and cancels the gesture instead
    /// of leaving it in flight forever.
    func testTruncatedStreamResolvesInsteadOfDangling() {
        var frames: [TouchFrame] = []
        var t = 0.0
        var x1 = 0.30, x2 = 0.40
        frames.append(TouchFrame(t: t, w: 400, h: 240, touches: [
            .init(id: 1, x: x1, y: 0.5, phase: .began),
            .init(id: 2, x: x2, y: 0.5, phase: .began),
        ]))
        for _ in 0..<5 {
            t += 0.01
            x1 += 0.01
            x2 += 0.01
            frames.append(TouchFrame(t: t, w: 400, h: 240, touches: [
                .init(id: 1, x: x1, y: 0.5, phase: .moved),
                .init(id: 2, x: x2, y: 0.5, phase: .moved),
            ]))
        }

        let recognizer = TrackpadGestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0) }
        TouchStreamReplay.run(frames: frames, recognizer: recognizer)
        XCTAssertEqual(events.first?.phase, .began)
        XCTAssertEqual(events.last?.phase, .cancelled)
        XCTAssertEqual(recognizer.state, .idle)
    }
}
