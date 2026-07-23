import Foundation

/// Deterministic replay of a recorded touch stream: parses the JSONL
/// recording format (one `TouchFrame` per line) and steps a synthetic
/// clock between frames so the settle timer fires exactly as it would
/// live. Same input, same output, every run - the gesture-lab CLI and
/// the fixture tests are both built on this.
public enum TouchStreamReplay {
    /// Parse JSONL text into frames. Malformed lines are skipped and
    /// reported by 1-based line number.
    public static func parse(_ text: String) -> (frames: [TouchFrame], malformedLines: [Int]) {
        let decoder = JSONDecoder()
        var frames: [TouchFrame] = []
        var malformed: [Int] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let frame = try? decoder.decode(TouchFrame.self, from: Data(trimmed.utf8)) {
                frames.append(frame)
            } else {
                malformed.append(index + 1)
            }
        }
        return (frames, malformed)
    }

    /// Feed frames through the recognizer in timestamp order, ticking a
    /// synthetic clock at `tickHz` between them. A `palmFilter` slots in
    /// ahead of the recognizer exactly as in a live host. `onStep`
    /// observes the clock just before each step, for timestamped
    /// logging.
    public static func run(frames: [TouchFrame],
                           recognizer: TrackpadGestureRecognizer,
                           tickHz: Double = 240,
                           palmFilter: PalmFilter? = nil,
                           onStep: ((TimeInterval) -> Void)? = nil) {
        guard let first = frames.first, let last = frames.last else { return }
        let feed: (TouchFrame) -> Void = { frame in
            if let palmFilter {
                if let filtered = palmFilter.process(frame) {
                    recognizer.process(filtered)
                }
            } else {
                recognizer.process(frame)
            }
        }
        let step = 1.0 / tickHz
        var clock = first.t
        var i = 0
        while clock <= last.t + step {
            onStep?(clock)
            while i < frames.count && frames[i].t <= clock {
                feed(frames[i])
                i += 1
            }
            recognizer.tick(now: clock)
            clock += step
        }
        while i < frames.count {
            feed(frames[i])
            i += 1
        }
    }
}
