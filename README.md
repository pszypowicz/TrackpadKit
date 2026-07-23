# TrackpadKit

A raw-`NSTouch` trackpad gesture engine for macOS: multi-finger swipes
and pinches recognized from the touch stream itself, with real finger
counts, deterministic replay, and coexistence with normal
`scrollWheel`/`magnify` handling instead of replacing it.

Why raw touches: AppKit's high-level `swipe(with:)` no longer fires for
trackpad swipes (macOS ships them as scroll events), scroll events
don't carry finger counts, and `NSGestureRecognizer` never receives
trackpad touches. The only way to get finger-count-aware gestures is to
read the `NSTouch` stream and recognize them yourself - TrackpadKit is
that recognizer, packaged.

The package has two parts:

- **`TrackpadKit`** - the library. A single-purpose engine with no
  AppKit dependency: driven by `TouchFrame` values, emits
  `GestureEvent { kind, direction, fingerCount, magnitude, velocity,
phase }`. Deterministic and replayable from disk.
- **`gesture-lab`** - the AppKit research harness the engine is
  developed and tuned in: live overlay, OS-event A/B counters,
  record/replay, threshold knobs.

## Using the library

```swift
// Package.swift
.package(url: "https://github.com/pszypowicz/TrackpadKit.git", from: "0.1.0")
```

```swift
import TrackpadKit

let recognizer = TrackpadGestureRecognizer()
recognizer.onGesture = { event in
    // .swipe: event.direction, magnitude in device points along the axis
    // .pinch: magnitude is scale relative to the spread at lock (1.0 = unchanged)
    // phases: .began / .changed / .ended (with fling velocity) / .cancelled
}
```

Feed it from your view's raw touch overrides by adapting `NSTouch` to
`TouchFrame` (map touch identities to small ints, keep
`normalizedPosition` plus `deviceSize`), and drive time forward from a
timer while touches are down - stationary fingers stop producing touch
events, but the settle timer still has to fire:

```swift
recognizer.process(TouchFrame(t: event.timestamp, w: pad.width, h: pad.height,
                              touches: samples))
recognizer.tick(now: ProcessInfo.processInfo.systemUptime)  // ~120 Hz while touching
```

`Sources/gesture-lab/TouchView.swift` is the reference host: first
responder setup, `allowedTouchTypes = [.indirect]`, the
`NSTouch -> TouchFrame` adaptation, and the tick timer.

## The gesture-lab harness

Requires macOS 14+ and a Swift 5.10 toolchain.

```sh
swift build
swift run gesture-lab                 # interactive lab window
swift run gesture-lab --replay fixtures/swipe-left-3f.jsonl
swift run gesture-lab --replay fixtures/swipe-left-3f.jsonl --verbose
swift run gesture-lab --replay recordings/rec.jsonl --palm-filter
swift test                            # replay every fixture, assert outcomes
```

Plain SwiftPM executable, programmatic `NSApplication`, no bundle. If
the app is frontmost and the cursor is over the window, trackpad touches
arrive; AppKit routes indirect touches (like scroll events) to the view
under the cursor, so keep the pointer inside the window while gesturing.

### Controls

| Key            | Action                                                    |
| -------------- | --------------------------------------------------------- |
| `r` (or Cmd+R) | start/stop recording to `recordings/*.jsonl`              |
| `c`            | reset the OS-event counters                               |
| `t`            | toggle `allowedTouchTypes` between `[.indirect]` and `[]` |
| `w`            | toggle `wantsRestingTouches` (see resting research)       |
| `f`            | toggle the PalmFilter stage                               |
| `s` / `S`      | swipe commit threshold down / up                          |
| `p` / `P`      | pinch commit threshold down / up                          |
| Cmd+O          | replay a recording (prints to the terminal)               |

## Files

- `Sources/TrackpadKit/TrackpadGestureRecognizer.swift` - the engine.
  Depends only on Foundation and CoreGraphics, never sees
  `NSTouch`/`NSEvent`.
- `Sources/TrackpadKit/PalmFilter.swift` - per-touch palm
  classification ahead of the recognizer (see Palm rejection below).
- `Sources/TrackpadKit/TouchStreamReplay.swift` - JSONL parsing and the
  deterministic replay clock shared by the CLI and the tests.
- `Sources/gesture-lab/TouchView.swift` - the lab surface and reference
  host; adapts `NSTouch` to `TouchFrame` and draws the overlay.
- `Sources/gesture-lab/Replay.swift` - the `--replay` CLI printer.
- `Sources/gesture-lab/TouchRecorder.swift` - JSONL frame recorder.
  Recordings land in `recordings/` (created on demand, gitignored).
- `Tests/TrackpadKitTests/` - replays every fixture and asserts the
  outcomes; a fixture without an expectation entry fails the suite.
  `fixtures/palm/` holds windows carved from real palm-planted
  recordings for the PalmFilter regression tests.
- `scripts/make-fixture.py` - synthetic gesture generator (see
  `--help`).
- `docs/palm-rejection.md` - the research (platform APIs, open-source
  stacks, literature, local measurements) behind the PalmFilter
  design.

## Recognizer model

Hand-rolled state machine, mirroring Apple's `DualTouchTracker` sample
rather than `NSGestureRecognizer` (which never receives trackpad
touches):

```
idle -> settling <-> locked(N) -> committed(swipe|pinch) -> idle
                                       \-> awaitingLift (drain until all fingers up)
```

- **Settling / finger-count lock**: any finger-count change restarts a
  60 ms settle timer, so staggered landings still lock the intended
  count and a transient extra contact leaves the surviving fingers as
  the candidate set; centroid motion over 2 pt locks immediately (a
  moving hand is done landing). A bare tap recognizes nothing.
  `wantsRestingTouches` stays false in the lab view, so resting thumbs
  are filtered by AppKit before we see them.
- **Commit-and-lock arbitration**: from the lock baseline both signals
  are measured continuously - centroid translation (swipe) and mean
  distance from centroid (pinch spread). First signal past its
  threshold captures the gesture for its whole lifetime; the other is
  ignored until the fingers lift. When both are near threshold in the
  same frame, the winner's threshold-relative ratio must exceed the
  loser's by the dominance margin, otherwise we stay in the deadzone
  and wait for a clearer frame. That margin is the main feel knob
  against sloppy diagonals.
- **Pre-commit count changes re-settle**: a contact joining or leaving
  before commit re-arms the settle window around the current touches.
  Nothing has been emitted yet, so there is nothing to protect by
  draining - draining here is what used to eat swipes grazed by a
  thumb or palm.
- **End vs cancel**: a lifted finger ends a committed gesture with a
  fling velocity (measured over the last 100 ms, so pausing before
  lifting flings at 0, like the OS); an added finger cancels it. Both
  drain until the trackpad is empty - one action per physical gesture.
- **Units**: positions are `normalizedPosition * deviceSize`, i.e.
  device points (1/72 in), so thresholds are trackpad-size independent.
  A 14" MacBook Pro pad and a Magic Trackpad need no retuning.

### Current thresholds

All in `TrackpadGestureRecognizer.Config`, live-tunable in the overlay:

| Knob                   | Default | Meaning                                                          |
| ---------------------- | ------- | ---------------------------------------------------------------- |
| `settleInterval`       | 60 ms   | quiet time after last landing before count lock                  |
| `motionLockThreshold`  | 2 pt    | settle-phase motion that locks immediately                       |
| `swipeCommitThreshold` | 10 pt   | centroid travel to commit a swipe (~3.5 mm)                      |
| `pinchCommitThreshold` | 8 pt    | mean-spread change to commit a pinch (16 pt between two fingers) |
| `dominanceMargin`      | 1.25    | hysteresis ratio when both signals are near threshold            |
| `velocityWindow`       | 100 ms  | velocity/fling estimation window                                 |
| `swipeFingerCounts`    | 2...4   | counts allowed to commit a swipe                                 |
| `pinchFingerCounts`    | 2...2   | counts allowed to commit a pinch                                 |
| `staleFrameTimeout`    | 400 ms  | frame gap that abandons a sequence (host stopped delivering)     |

## Palm rejection

macOS exposes no contact size, pressure, or reliable resting flag for
trackpad touches, so a palm arrives as ordinary touches - typically a
churn of short-lived contacts near the pad's bottom edge that inflate
the finger count. `PalmFilter` is the classification stage every
mature input stack places ahead of gesture recognition:

```
host adapter -> PalmFilter -> TrackpadGestureRecognizer
```

A touch is a suspect if it is born in the bottom band (default: lowest
20% of the pad) or while an established finger is already in motion
(the late-lander rule: gesture fingers land before motion starts, palm
patches materialize mid-swipe). Suspects are withheld from the stream;
one is promoted to a finger only by deliberate monotonic travel (palm
smears jitter and never qualify), and one that rests near its origin
past a timeout becomes a palm for its whole lifetime. Hosts opt in by
piping frames through `PalmFilter.process(_:)`; the recognizer is
untouched.

Not handled (yet): palm patches born mid-pad during quiet gaps between
gestures - above any viable band, with no finger motion at birth.
Candidate mechanisms, and the research and measurements behind the
current design: [docs/palm-rejection.md](docs/palm-rejection.md).

## Record / replay

Recording writes one JSON object per touch frame:

```json
{
  "t": 1000.011,
  "w": 400.0,
  "h": 240.0,
  "touches": [{ "id": 1, "x": 0.55, "y": 0.48, "phase": "moved" }]
}
```

`t` is the event timestamp (only deltas matter), `w`/`h` are
`NSTouch.deviceSize`, positions are normalized. Replay steps a
synthetic 240 Hz clock between frames so the settle timer fires exactly
as it would live: same file in, same gestures out, every run. The
fixture tests (`swift test`) pin this down in CI.

## Findings

Recognizer and PalmFilter behavior is asserted by deterministic replay
in `swift test` - the expectation tables in `Tests/TrackpadKitTests/`
are the authoritative record of what each fixture must produce.

### To confirm on hardware (needs a hand on the trackpad)

The instrumentation is built; these are the observations the overlay is
designed to produce, in priority order:

1. **Double-source**: do a 2-finger swipe. Expect the scroll counter's
   `live` count and the tracker's touch stream to advance for the same
   physical motion, and `during committed swipe` to go positive: proof
   the same motion arrives twice and that only the tracker emits a
   gesture action (scroll deltas are only logged/accumulated, and
   momentum copies are identified by `momentumPhase != []` and counted
   separately). Gestures are impossible from the momentum tail since no
   touches are down during it.
2. **Coexistence**: pinch with the OS `magnify:` A/B line visible.
   Expect both the OS scale and ours to track each other, with neither
   stream degraded. Scroll should feel untouched while the tracker is
   armed.
3. **`swipe(with:)` premise**: the overlay counts calls to the
   high-level `swipe(with:)` override. Prior testing on macOS 26.x saw
   zero; the counter turns red if it ever fires, which would weaken the
   raw-touch justification.
4. **Touch-vs-scroll delivery**: press `t` to flip `allowedTouchTypes`
   between `[.indirect]` and `[]`, then compare scroll live/momentum
   counts for the same physical swipe in both modes. This answers the
   undocumented question of whether opting into indirect touches
   changes `scrollWheel` delivery.

### Native-feel notes

- Two-finger swipes and scrolling are the same physical motion; the
  recognizer will commit a 2-finger swipe on any 10 pt translation.
  When porting, either narrow `swipeFingerCounts` to 3...4 or gate the
  2-finger case on the app not wanting scroll. The lab keeps 2 enabled
  precisely to observe the collision.
- The OS pinch (`magnify:`) begins with no visible deadzone; ours needs
  8 pt of spread change. Matching the OS exactly would mean committing
  earlier and risking swipe misclassification - the dominance margin is
  the compromise, and the A/B line exists to tune it by feel.
- No rotation, by design.
- `smartMagnify:` (two-finger double-tap) has no raw-touch equivalent
  worth building; the two taps are trivial to see in the touch stream,
  but the OS timing/slop heuristics are opaque, so keep using the
  callback (it is counted in the overlay to confirm it coexists).
