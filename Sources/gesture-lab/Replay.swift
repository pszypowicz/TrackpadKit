import Foundation

/// Headless replay: feeds a recorded (or synthesized) JSONL touch stream
/// through a fresh recognizer and prints what it recognizes. Time is
/// stepped synthetically between frames so the settle timer fires exactly
/// as it would live - same input file, same output, every run.
enum Replay {
    static func run(path: String, verbose: Bool) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            fputs("replay: cannot read \(path)\n", stderr)
            return 1
        }

        let decoder = JSONDecoder()
        var frames: [TouchFrame] = []
        var badLines = 0
        for (index, line) in text.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let frame = try? decoder.decode(TouchFrame.self, from: Data(trimmed.utf8)) {
                frames.append(frame)
            } else {
                badLines += 1
                if verbose { fputs("replay: skipping malformed line \(index + 1)\n", stderr) }
            }
        }
        guard !frames.isEmpty else {
            fputs("replay: no frames in \(path)\n", stderr)
            return 1
        }

        let t0 = frames[0].t
        var clock = t0
        let recognizer = TrackpadGestureRecognizer()
        var eventCounts: [String: Int] = [:]
        var changedCount = 0

        recognizer.onGesture = { e in
            let key = "\(e.kind.rawValue) \(e.phase.rawValue)"
            eventCounts[key, default: 0] += 1
            if e.phase == .changed {
                changedCount += 1
                if !verbose { return }
            }
            let dir = e.direction == .none ? "" : " \(e.direction.rawValue)"
            print(String(format: "[%7.3fs] %@%@ %df  %@ %.2f  vel %.1f/s",
                         clock - t0, e.kind.rawValue, dir, e.fingerCount,
                         e.phase.rawValue, e.magnitude, e.velocity))
        }
        recognizer.onStateChange = { state in
            if verbose {
                print(String(format: "[%7.3fs] state -> %@", clock - t0, state.label))
            }
        }

        let step = 1.0 / 240.0
        let tEnd = frames.last!.t
        var i = 0
        while clock <= tEnd + step {
            while i < frames.count && frames[i].t <= clock {
                recognizer.process(frames[i])
                i += 1
            }
            recognizer.tick(now: clock)
            clock += step
        }
        while i < frames.count {
            recognizer.process(frames[i])
            i += 1
        }

        print("---")
        print(String(format: "replayed %d frames over %.3fs from %@",
                     frames.count, tEnd - t0, path))
        if badLines > 0 { print("skipped \(badLines) malformed lines") }
        if eventCounts.isEmpty {
            print("no gestures recognized")
        } else {
            for key in eventCounts.keys.sorted() {
                print("  \(key): \(eventCounts[key]!)")
            }
        }
        return 0
    }
}
