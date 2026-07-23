# Palm rejection research and design

Why TrackpadKit needs its own palm rejection, what the platform and the
rest of the industry offer, and the design this package adopts. Written
against empirical data from `recordings/` (a 31 s palm-planted session
and two clean sessions on a MacBook Pro trackpad).

## The problem, measured

A palm resting on the pad does not arrive as one stable touch. In the
palm session it produced 258 distinct touch ids in 31 seconds - a churn
of short-lived contacts (10-600 ms lifetimes, mostly small motion),
concentrated in the pad's bottom band. Two failure modes follow:

- Count inflation: palm contacts present during the settle window lock
  a 2-finger swipe as 3 or 4 fingers.
- Mid-gesture cancellation: palm micro-contacts landing during a
  committed gesture cancel it (an added finger cancels by design).

Local separability results (palm session vs two clean sessions):

- Birth position is decisively separating for a natural grip: 113/258
  palm-session contacts dipped below normalized y = 0.15; across both
  clean sessions, zero intentional contacts ever entered that band.
- Travel alone is not separating: 85 palm-session contacts moved 30 pt
  or more (palm smears move).
- Churn rate alone is not separating: an intense clean session produced
  nearly the same touch-birth rate (7.3/s vs 8.2/s).

## What macOS provides (and doesn't)

The public API's entire palm story is `NSTouch.isResting` plus
`NSView.wantsRestingTouches`, and it is not usable as a mechanism:

- Apple documents the classification as driver-owned and unstable: the
  driver "might transition a touch into or out of a resting status at
  any time", movement "is not always the determinant" (Cocoa Event
  Handling Guide). Measured here: the flag flickers per sample on the
  view path (one contact flagged in 2 of its 84 samples) and several
  palm-band contacts are never flagged at all.
- The concept exists only on the view-delivery path. On an
  `NSEvent.addLocalMonitorForEvents(.gesture)` + `allTouches()` path,
  a full palm session produced zero resting flags.
- It is documented as a thumb-at-the-bottom-edge concept, not palm
  detection.

No public API exposes per-contact size, pressure, or ellipse: NSTouch
has no equivalent of iOS `UITouch.majorRadius`; `NSEvent.pressure` is
per-event (Force Touch); CGEventTap has no trackpad contact fields; no
public IOKit/HID path exists. The hardware measures all of it - Linux
drivers for the same silicon (bcm5974, hid-magicmouse) report contact
major/minor axes, orientation, and pressure, and libinput's Apple
quirks set size thresholds from that channel - but on macOS that data
stops at the private layer.

The private `MultitouchSupport.framework` exposes exactly the missing
data (per-contact size, major/minor axis, angle, density, state).
Karabiner-Elements ships size-threshold palm rejection on it
(`palmThreshold`); OpenMultitouchSupport is an actively maintained
wrapper. Constraints: dlopen/dlsym only (arm64e pointer authentication
breaks direct linking), sandbox off, App Store disqualifying,
empirical struct layout. Viable as an optional enhancement for
non-sandboxed hosts, never as the base mechanism.

Apple's own rejection behavior (their scroll recognizer scrolls
cleanly with a palm planted while the raw stream shows 3-4 contacts)
is consistent with their patents: US7561146 (reject by size, location,
and trajectory) and US10747428 (edge-band rejection with escape by
motion, plus admitting an edge contact whose movement tracks the
center contacts).

## How mature open-source stacks do it

All of them - libinput, ChromiumOS gestures, xf86-input-synaptics,
mtrack, Windows Precision Touchpad - converge on the same shape:

- Palm/thumb classification is a distinct stage between raw touch
  ingestion and gesture recognition.
- Per-touch state machines keyed by stable id; touches are flagged or
  quarantined, not deleted, so they can be promoted retroactively.
- Gesture recognition consumes only touches classified as fingers.
- Thresholds operate in physical units (mm), converted before
  comparison.

Key portable heuristics (validated without size/pressure data):

| Heuristic                   | Details                                                                                                                                                 | Source               |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| Birth-zone prior            | Classify by where the touch began, never where it moved. libinput thumb lines at 85% and 92% of pad height; side zones min(8 mm, 8%); mtrack bottom 10% | libinput, mtrack     |
| Quarantine, don't drop      | libinput JAILED state; ChromiumOS 0.1 s eval window + WARP flags: suspects are tracked but withheld until they prove intent                             | libinput, ChromiumOS |
| Escape by deliberate motion | Monotonic travel >= 8 mm with <= 0.3 mm reverse (ChromiumOS); leave edge zone within 200 ms in a plausible direction (libinput)                         | ChromiumOS, libinput |
| Speed accumulator           | Frames above 20 mm/s increment a counter; 10+ counts = definitely a finger                                                                              | libinput             |
| Stationary aging            | < 4 mm from origin for 2.0 s inside a suspect zone -> palm                                                                                              | ChromiumOS           |
| Group timing coherence      | Touches all born within 100 ms and above the thumb line are all intentional; a late straggler > 25 mm below the others is a thumb                       | libinput             |
| Proximity rescue            | A suspect near a live finger (but > 4 mm away, guarding split contacts) is promoted                                                                     | ChromiumOS, libinput |
| Sticky palm                 | Once palm, always palm; release only through enumerated escapes; never flap per frame                                                                   | libinput, ChromiumOS |

## What the literature adds

- Spatiotemporal features without contact area still work: Schwarz et
  al. (CHI 2014) found min-distance-to-other-touches and event count
  among the top features; a reimplementation without area features
  scored F1 0.87 (Xu et al., IMWUT 2020). Position+time static rules
  alone reach ~80% rejection (Matero and Colley, DIS 2012).
- Palm churn is a documented signature: palms arrive "segmented into a
  collection of touch points which flicker in and out" (Schwarz);
  after a first resting touch, a second lands within 100 ms in 86% of
  cases (TypeBoard, UIST 2021).
- Deferred decisions are nearly free on a trackpad: latency JND for
  indirect touch is ~55 ms (dragging) / ~96 ms (tapping) (Deber et
  al., CHI 2015). Classification accuracy plateaus by 100-200 ms
  (Schwarz). A 50-100 ms quarantine is at or below perception - and
  TrackpadKit's recognizer already waits out a 60 ms settle window, so
  quarantine adds no perceived latency to gesture starts.
- Prefer exclude-then-admit over classify-and-retract for continuous
  gestures: a suspect contributes nothing until it proves itself;
  retracting a recognized gesture is far more disruptive than
  retracting a drawn stroke.

## Design: the PalmFilter stage

TrackpadKit adopts the industry-consensus architecture:

```
host adapter -> PalmFilter -> TrackpadGestureRecognizer
 (NSTouch ->    (TouchFrame ->   (TouchFrame ->
  TouchFrame)    TouchFrame)      GestureEvent)
```

- `PalmFilter` is a pure, deterministic `TouchFrame -> TouchFrame`
  transform, same contract as the recognizer: replayable from disk,
  fixture-testable, host-independent. Hosts opt in by piping frames
  through it; the recognizer is untouched.
- Per-touch state machine keyed by id: `finger`, `pending`
  (quarantined suspect, withheld from output), `palm` (sticky,
  withheld for the contact's lifetime).
- v1 heuristics, seeded from the sources above and local data:
  - A touch born in the bottom band (default: lowest 15% of pad
    height; local data shows zero intentional contacts there) enters
    `pending` instead of `finger`.
  - `pending` -> `finger`: monotonic travel past a threshold
    (~~8 mm =~~ 23 device pt), or velocity tracking the established
    finger set (correlated motion, per the Apple patent).
  - `pending` -> `palm`: short life ending in the band, stationary
    aging, or membership in a birth burst clustered with other
    suspects.
  - `palm` is sticky until lift.
- All thresholds live in a `PalmFilter.Config` in device points,
  tunable in the lab overlay like the recognizer's.
- Optional future extension: hosts that read the private
  MultitouchSupport framework can stamp contact size into
  `TouchSample` (an optional field, like `resting`); the filter uses
  size thresholds when present and heuristics otherwise, degrading
  cleanly. The public-API path never depends on it.

Explicitly rejected:

- `isResting` as a mechanism (flaky by documentation and measurement,
  absent on the monitor path). The recorder still captures it for
  research.
- In-recognizer palm logic: the recognizer recognizes gestures from
  fingers; deciding what is a finger is the stage before it.
- Bare finger-count matching or abort-on-extra-contact (Apple's
  LightTable pattern, MiddleClick): that is what produced the original
  failure mode.

## Sources

Apple: [NSTouch.isResting](https://developer.apple.com/documentation/appkit/nstouch/isresting),
[wantsRestingTouches](https://developer.apple.com/documentation/appkit/nsview/wantsrestingtouches),
[Cocoa Event Handling Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html),
patents [US7561146](https://patents.google.com/patent/US7561146B1/en),
[US10747428](https://patents.google.com/patent/US10747428B2/en).
Private framework: [OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport),
[Karabiner-Elements MultitouchExtension](https://deepwiki.com/pqrs-org/Karabiner-Elements/7.3-multitouch-extension),
[mactic arm64e notes](https://github.com/MatMercer/mactic).
Open source: [libinput palm detection](https://wayland.freedesktop.org/libinput/doc/latest/palm-detection.html),
[ChromiumOS PalmClassifyingFilterInterpreter](https://chromium.googlesource.com/chromiumos/platform/gestures/+/refs/heads/main/src/palm_classifying_filter_interpreter.cc),
[mtrack](https://github.com/BlueDragonX/xf86-input-mtrack),
[bcm5974](https://github.com/torvalds/linux/blob/master/drivers/input/mouse/bcm5974.c),
[Windows PTP tuning](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchpad-tuning-guidelines).
Literature: [Schwarz et al. CHI 2014](https://dl.acm.org/doi/10.1145/2556288.2557056),
[Le et al. (PalmTouch) CHI 2018](https://dl.acm.org/doi/10.1145/3173574.3173934),
[Xu et al. IMWUT 2020](https://dl.acm.org/doi/10.1145/3381011),
[Gu et al. (TypeBoard) UIST 2021](https://dl.acm.org/doi/10.1145/3472749.3474770),
[Matero and Colley DIS 2012](https://dl.acm.org/doi/10.1145/2317956.2318031),
[Deber et al. CHI 2015](https://dl.acm.org/doi/10.1145/2702123.2702300),
[Annett et al. TOCHI 2014](https://dl.acm.org/doi/10.1145/2674915).
