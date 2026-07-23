import Foundation
import TrackpadKit

/// Headless replay CLI: runs a recorded (or synthesized) JSONL touch
/// stream through a fresh recognizer via `TouchStreamReplay` and prints
/// what it recognizes.
enum Replay {
    static func run(path: String, verbose: Bool) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            fputs("replay: cannot read \(path)\n", stderr)
            return 1
        }

        let (frames, malformed) = TouchStreamReplay.parse(text)
        if verbose {
            for line in malformed {
                fputs("replay: skipping malformed line \(line)\n", stderr)
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

        recognizer.onGesture = { e in
            let key = "\(e.kind.rawValue) \(e.phase.rawValue)"
            eventCounts[key, default: 0] += 1
            if e.phase == .changed && !verbose { return }
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

        TouchStreamReplay.run(frames: frames, recognizer: recognizer) { clock = $0 }

        print("---")
        print(String(format: "replayed %d frames over %.3fs from %@",
                     frames.count, frames.last!.t - t0, path))
        if !malformed.isEmpty { print("skipped \(malformed.count) malformed lines") }
        let samples = frames.flatMap(\.touches)
        let tagged = samples.filter { $0.resting != nil }
        if !tagged.isEmpty {
            let restingIDs = Set(tagged.filter { $0.resting == true }.map(\.id))
            print("resting: \(tagged.filter { $0.resting == true }.count) of \(tagged.count) "
                + "tagged samples, touch ids \(restingIDs.sorted())")
        }
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
