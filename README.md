# gesture-lab

A standalone AppKit lab for prototyping a raw-`NSTouch` trackpad
gesture recognizer on macOS - multi-finger swipes and pinches
recognized from the touch stream itself, coexisting with normal
`scrollWheel`/`magnify` handling instead of replacing it.

The recognizer is a single portable file with no AppKit dependency,
written to be lifted into a real app (originally a Ghostty fork). The
lab around it exists because iterating on gesture feel inside a big app
is minutes per build; here it is seconds, and every tuning question has
either an on-screen counter or a deterministic replay to answer it.

## Build and run

Requires macOS 14+ and a Swift 5.10 toolchain.

```sh
swift build
swift run gesture-lab                 # interactive lab window
swift run gesture-lab --replay fixtures/swipe-left-3f.jsonl
swift run gesture-lab --replay fixtures/swipe-left-3f.jsonl --verbose
```

Plain SwiftPM executable, programmatic `NSApplication`, no bundle. If
the app is frontmost and the cursor is over the window, trackpad touches
arrive; AppKit routes indirect touches (like scroll events) to the view
under the cursor, so keep the pointer inside the window while gesturing.
If touches ever fail to arrive as a bare executable, the fallback is a
minimal `.app` wrapper, but that has not been needed so far.

## Files

- `Sources/gesture-lab/TrackpadGestureRecognizer.swift` - the portable
  deliverable. Depends only on Foundation and CoreGraphics, never sees
  `NSTouch`/`NSEvent`, is driven by `TouchFrame` values and emits
  `GestureEvent { kind, direction, fingerCount, magnitude, velocity,
phase }`. This is the file to lift into your app.
- `Sources/gesture-lab/TouchView.swift` - the lab surface, set up the
  way a real app's view would be (`acceptsFirstResponder`,
  `allowedTouchTypes = [.indirect]`, raw touch overrides, real
  `scrollWheel`/`magnify` overrides). Adapts `NSTouch` to `TouchFrame`
  (identity objects mapped to small ints via copied identities as
  dictionary keys) and draws the overlay.
- `Sources/gesture-lab/Replay.swift` - headless deterministic replay.
- `Sources/gesture-lab/TouchRecorder.swift` - JSONL frame recorder.
  Recordings land in `recordings/` (created on demand, gitignored).
- `scripts/make-fixture.py` - synthetic gesture generator (see
  `--help`).

## Controls

| Key            | Action                                                    |
| -------------- | --------------------------------------------------------- |
| `r` (or Cmd+R) | start/stop recording to `recordings/*.jsonl`              |
| `c`            | reset the OS-event counters                               |
| `t`            | toggle `allowedTouchTypes` between `[.indirect]` and `[]` |
| `s` / `S`      | swipe commit threshold down / up                          |
| `p` / `P`      | pinch commit threshold down / up                          |
| Cmd+O          | replay a recording (prints to the terminal)               |

## Recognizer model

Hand-rolled state machine, mirroring Apple's `DualTouchTracker` sample
rather than `NSGestureRecognizer` (which never receives trackpad
touches):

```
idle -> settling -> locked(N) -> committed(swipe|pinch) -> idle
                        \-> awaitingLift (drain until all fingers up)
```

- **Settling / finger-count lock**: every added finger restarts a 60 ms
  settle timer, so staggered landings still lock the intended count;
  centroid motion over 2 pt locks immediately (a moving hand is done
  landing). A finger lifting before lock (a tap) drains without
  recognizing. `wantsRestingTouches` stays false, so resting thumbs are
  filtered by AppKit before we see them.
- **Commit-and-lock arbitration**: from the lock baseline both signals
  are measured continuously - centroid translation (swipe) and mean
  distance from centroid (pinch spread). First signal past its
  threshold captures the gesture for its whole lifetime; the other is
  ignored until the fingers lift. When both are near threshold in the
  same frame, the winner's threshold-relative ratio must exceed the
  loser's by the dominance margin, otherwise we stay in the deadzone
  and wait for a clearer frame. That margin is the main feel knob
  against sloppy diagonals.
- **End vs cancel**: a lifted finger ends a committed gesture with a
  fling velocity (measured over the last 100 ms, so pausing before
  lifting flings at 0, like the OS); an added finger cancels it. Both
  drain until the trackpad is empty.
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
as it would live: same file in, same gestures out, every run.

## Findings

### Verified by deterministic replay (synthetic fixtures)

All of `fixtures/` replays to the expected result with the default
thresholds:

- 3-finger left, 2-finger up, 4-finger right swipes: correct kind,
  direction, and count; fling velocity matches the synthetic motion
  (e.g. 100 pt over 0.25 s reports ~400 pt/s).
- Staggered 3-finger landing (30 ms apart, with jitter) still locks 3
  and swipes; state trace is settling -> locked(3) -> committed(swipe)
  -> idle.
- Pinch out/in: scale 1.58 / 0.61 with signed velocity.
- Noisy pinch stays a pinch, noisy swipe stays a swipe (no
  cross-commit), a 2-finger tap and a sub-threshold wander recognize
  nothing, and a 3-finger pinch is rejected because pinch only commits
  at 2 fingers.

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
