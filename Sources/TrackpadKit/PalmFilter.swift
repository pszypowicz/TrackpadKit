import Foundation
import CoreGraphics

/// Per-touch palm classification ahead of gesture recognition: a pure
/// TouchFrame -> TouchFrame transform hosts pipe frames through before
/// the recognizer, mirroring the classification stage every mature
/// input stack places between touch ingestion and gestures (libinput,
/// ChromiumOS gestures - see docs/palm-rejection.md for the research
/// this design distills).
///
/// macOS exposes no contact size, pressure, or reliable resting flag
/// for trackpad touches, so classification rests on the two signals a
/// position-only stream offers:
///
/// - Birth position: palms and resting thumbs land in the pad's bottom
///   band; intentional touches essentially never do. A touch BORN there
///   is a suspect and is withheld from the output. Where it later moves
///   never changes the initial classification.
/// - Deliberate motion: a suspect that travels monotonically (forward
///   progress with almost no reverse) is promoted to a finger and
///   enters the stream with a synthetic began. Palm smears drift and
///   jitter; they accumulate reverse motion and never qualify.
///
/// States per touch: finger (passed through), pending (withheld,
/// promotable), palm (withheld, sticky until lift). A pending touch
/// that sits near its origin past the stationary timeout becomes palm,
/// so a late smear of a long-resting contact can no longer promote.
public final class PalmFilter {

    public struct Config {
        /// Height of the bottom exclusion band as a fraction of pad
        /// height (normalized y, origin bottom). Touches born below
        /// this are suspects; 0 disables the filter.
        public var bottomBand: Double = 0.20
        /// Monotonic travel (device pt) along one axis that promotes a
        /// suspect to a finger; nil makes the band definitive
        /// (suspects never promote).
        public var promotionTravel: Double? = 23.0
        /// Reverse motion (device pt) tolerated along the promoting
        /// axis. Strictness is the point: palm smears jitter, so even
        /// a small tolerance keeps nearly all of them out.
        public var promotionReverseTolerance: Double = 1.0
        /// A pending touch staying within this radius (device pt) of
        /// its origin for `stationaryTimeout` becomes a palm.
        public var stationaryRadius: Double = 12.0
        public var stationaryTimeout: TimeInterval = 2.0

        public init() {}
    }

    public enum TouchState {
        case finger, pending, palm
    }

    public var config = Config()

    private struct Tracked {
        var state: TouchState
        var origin: CGPoint
        var originTime: TimeInterval
        var last: CGPoint
        /// Per-axis sums of positive/negative deltas since birth, for
        /// the monotonic promotion test.
        var forward = CGVector.zero
        var reverse = CGVector.zero
        var stationary = true
    }

    private var touches: [Int: Tracked] = [:]

    public init() {}

    /// Current classification of a live touch (for host overlays).
    public func state(of id: Int) -> TouchState? { touches[id]?.state }

    /// Live suspect count (for host overlays).
    public var suppressedCount: Int {
        touches.values.filter { $0.state != .finger }.count
    }

    public func reset() { touches.removeAll() }

    /// Classify one frame. Returns the frame with suspect touches
    /// removed, or nil when no touches remain - hosts skip the
    /// recognizer for nil frames.
    public func process(_ frame: TouchFrame) -> TouchFrame? {
        var out: [TouchSample] = []
        for sample in frame.touches {
            let p = CGPoint(x: sample.x * frame.w, y: sample.y * frame.h)
            switch sample.phase {
            case .began:
                let suspect = config.bottomBand > 0 && sample.y < config.bottomBand
                let state: TouchState = if !suspect {
                    .finger
                } else if config.promotionTravel == nil {
                    .palm
                } else {
                    .pending
                }
                touches[sample.id] = Tracked(state: state, origin: p,
                                             originTime: frame.t, last: p)
                if state == .finger { out.append(sample) }

            case .ended, .cancelled:
                if let tracked = touches.removeValue(forKey: sample.id),
                   tracked.state == .finger {
                    out.append(sample)
                }

            case .moved, .stationary:
                guard var tracked = touches[sample.id] else {
                    // Unknown id: the host attached mid-sequence. Treat
                    // as a finger - suspicion needs a birth position.
                    touches[sample.id] = Tracked(state: .finger, origin: p,
                                                 originTime: frame.t, last: p)
                    out.append(sample)
                    continue
                }
                let dx = p.x - tracked.last.x
                let dy = p.y - tracked.last.y
                if dx > 0 { tracked.forward.dx += dx } else { tracked.reverse.dx -= dx }
                if dy > 0 { tracked.forward.dy += dy } else { tracked.reverse.dy -= dy }
                tracked.last = p

                switch tracked.state {
                case .finger:
                    out.append(sample)
                case .palm:
                    break
                case .pending:
                    if tracked.stationary && distance(p, tracked.origin) > config.stationaryRadius {
                        tracked.stationary = false
                    }
                    if tracked.stationary,
                       frame.t - tracked.originTime >= config.stationaryTimeout {
                        tracked.state = .palm
                    } else if promotes(tracked) {
                        tracked.state = .finger
                        // Synthetic began: downstream sees a fresh
                        // landing at the touch's current position.
                        out.append(TouchSample(id: sample.id, x: sample.x, y: sample.y,
                                               phase: .began, resting: sample.resting))
                    }
                }
                touches[sample.id] = tracked
            }
        }
        guard !out.isEmpty else { return nil }
        return TouchFrame(t: frame.t, w: frame.w, h: frame.h, touches: out)
    }

    private func promotes(_ tracked: Tracked) -> Bool {
        guard let travel = config.promotionTravel else { return false }
        let eps = config.promotionReverseTolerance
        return (tracked.forward.dx >= travel && tracked.reverse.dx <= eps)
            || (tracked.reverse.dx >= travel && tracked.forward.dx <= eps)
            || (tracked.forward.dy >= travel && tracked.reverse.dy <= eps)
            || (tracked.reverse.dy >= travel && tracked.forward.dy <= eps)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
