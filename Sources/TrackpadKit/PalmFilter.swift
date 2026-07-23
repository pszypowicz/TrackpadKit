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
/// - Landing time: gesture fingers all land before the motion starts
///   (the recognizer's settle window models exactly that), so a touch
///   born while established fingers are already in fast motion is a
///   suspect wherever it lands - palm patches materialize mid-swipe,
///   including well above any edge band. This is libinput's
///   thumb-dropped-while-scrolling rule.
///
/// States per touch: finger (passed through), pending (withheld,
/// promotable), palm (withheld, sticky until lift). A pending touch
/// that sits near its origin past the stationary timeout becomes palm,
/// so a late smear of a long-resting contact can no longer promote.
///
/// Not thread-safe: drive from a single queue (typically main).
/// `config` may be mutated between frames; changes take effect on the
/// next processed frame.
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

        /// Late-lander rule: a touch born while an established finger
        /// is in motion is a suspect regardless of position. A finger
        /// counts as in motion once it accumulates this many device
        /// points of travel without pausing longer than
        /// `lateLanderRecency` (0 disables the rule) - lifetime travel
        /// doesn't count, so a finger that swiped once and then rested
        /// is not "in motion" when it later twitches.
        public var lateLanderMinFingerTravel: Double = 10.0
        /// Pause that ends a run of motion (and the maximum age of the
        /// last movement for the finger to count as in motion).
        public var lateLanderRecency: TimeInterval = 0.15

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
        var lastMoveTime: TimeInterval
        /// Travel accumulated in the current run of motion; reset when
        /// the touch pauses longer than the late-lander recency.
        var recentTravel: Double = 0
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

    public func reset() { touches.removeAll() }

    /// Classify one frame. Returns the frame with suspect touches
    /// removed, or nil when no touches remain - hosts skip the
    /// recognizer for nil frames.
    public func process(_ frame: TouchFrame) -> TouchFrame? {
        // A frame carries every live touch (the TouchFrame contract), so
        // a tracked id absent from one is a touch whose ended was never
        // delivered - the host stopped receiving events mid-sequence.
        // Forget such phantoms: a later reuse of the id must not inherit
        // their classification.
        let live = Set(frame.touches.map(\.id))
        touches = touches.filter { live.contains($0.key) }

        // Landing classification uses the motion state at frame start,
        // so every landing in a frame sees the same answer regardless
        // of sample order (live hosts deliver touches in set order).
        let landingDuringMotion = fingersInMotion(at: frame.t)

        var out: [TouchSample] = []
        for sample in frame.touches {
            let p = CGPoint(x: sample.x * frame.w, y: sample.y * frame.h)
            switch sample.phase {
            case .began:
                if let admitted = admit(sample, at: p, time: frame.t,
                                        duringMotion: landingDuringMotion) {
                    out.append(admitted)
                }

            case .ended, .cancelled:
                if let tracked = touches.removeValue(forKey: sample.id),
                   tracked.state == .finger {
                    out.append(sample)
                }

            case .moved, .stationary:
                guard var tracked = touches[sample.id] else {
                    // Unknown id: the host attached mid-sequence or
                    // remapped ids under a still-down hand. Classify by
                    // the current position as a birth estimate - a
                    // resting palm re-entering here must not become a
                    // finger just because its true landing wasn't seen.
                    // Admission enters the stream as a synthetic began,
                    // same as promotion: downstream sees a fresh landing.
                    if admit(sample, at: p, time: frame.t,
                             duringMotion: landingDuringMotion) != nil {
                        out.append(TouchSample(id: sample.id, x: sample.x, y: sample.y,
                                               phase: .began, resting: sample.resting))
                    }
                    continue
                }
                let dx = p.x - tracked.last.x
                let dy = p.y - tracked.last.y
                if dx > 0 { tracked.forward.dx += dx } else { tracked.reverse.dx -= dx }
                if dy > 0 { tracked.forward.dy += dy } else { tracked.reverse.dy -= dy }
                if frame.t - tracked.lastMoveTime > config.lateLanderRecency {
                    tracked.recentTravel = 0
                }
                tracked.recentTravel += abs(dx) + abs(dy)
                if abs(dx) + abs(dy) >= 0.5 { tracked.lastMoveTime = frame.t }
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

    /// Classify a newly seen touch (a began sample, or an unknown id
    /// appearing mid-life) and track it. Returns the sample when it is
    /// admitted as a finger.
    private func admit(_ sample: TouchSample, at p: CGPoint,
                       time: TimeInterval, duringMotion: Bool) -> TouchSample? {
        let suspect = (config.bottomBand > 0 && sample.y < config.bottomBand)
            || duringMotion
        let state: TouchState = if !suspect {
            .finger
        } else if config.promotionTravel == nil {
            .palm
        } else {
            .pending
        }
        touches[sample.id] = Tracked(state: state, origin: p,
                                     originTime: time, last: p,
                                     lastMoveTime: time)
        return state == .finger ? sample : nil
    }

    /// True when any established finger is in a current run of motion
    /// long enough that a landing right now is a late lander.
    private func fingersInMotion(at now: TimeInterval) -> Bool {
        guard config.lateLanderMinFingerTravel > 0 else { return false }
        return touches.values.contains { tracked in
            tracked.state == .finger
                && tracked.recentTravel >= config.lateLanderMinFingerTravel
                && now - tracked.lastMoveTime <= config.lateLanderRecency
        }
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
