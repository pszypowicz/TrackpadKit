#!/usr/bin/env python3
"""Generate synthetic trackpad touch streams in gesture-lab's JSONL
replay format, for deterministic recognizer testing and threshold tuning
without a hand on the trackpad.

Coordinates are normalized (0..1, origin bottom-left, y up); the device
size stamps each frame so the recognizer works in device points.
"""

import argparse
import json
import math
import random
import sys


DIRECTIONS = {
    "left": (-1.0, 0.0),
    "right": (1.0, 0.0),
    "up": (0.0, 1.0),
    "down": (0.0, -1.0),
}


def clamp(v):
    return max(0.02, min(0.98, v))


def build_frames(args):
    rng = random.Random(args.seed)
    n = args.fingers
    t0 = 1000.0
    dt = 1.0 / args.rate
    frames = []

    # Fingers on a circle around the start centroid, circular in device
    # space so pinch spread is isotropic.
    cx, cy = 0.5, 0.5
    radius_dev = args.start_radius
    offsets = []
    for i in range(n):
        angle = 2 * math.pi * i / n + (math.pi / 6 if n > 1 else 0)
        offsets.append((radius_dev * math.cos(angle) / args.device_width,
                        radius_dev * math.sin(angle) / args.device_height))

    land_time = {i: i * args.stagger for i in range(n)}
    last_land = max(land_time.values())
    move_start = last_land + args.hold
    move_end = move_start + args.duration
    if args.kind == "tap":
        move_start = move_end = last_land + args.tap_hold

    def positions(t):
        """Per-finger normalized positions at time t (motion progress)."""
        progress = 0.0
        if t > move_start:
            progress = min(1.0, (t - move_start) / max(1e-9, move_end - move_start))
        pts = {}
        for i in range(n):
            ox, oy = offsets[i]
            if args.kind == "pinch":
                grow = 1.0 + (args.scale_end - 1.0) * progress
                x, y = cx + ox * grow, cy + oy * grow
            elif args.kind == "swipe":
                dx, dy = DIRECTIONS[args.direction]
                x = cx + ox + dx * args.travel * progress
                y = cy + oy + dy * args.travel * progress
            else:  # tap, wander
                x, y = cx + ox, cy + oy
            if args.jitter > 0:
                x += rng.gauss(0, args.jitter)
                y += rng.gauss(0, args.jitter)
            pts[i] = (clamp(x), clamp(y))
        return pts

    # Optional transient extra touch (a thumb grazing the pad edge): lands
    # at --transient-at, sits stationary, lifts after --transient-duration.
    transient_id = n + 1
    transient_pos = (clamp(args.transient_x), clamp(args.transient_y))
    transient_lift = None
    if args.transient_at is not None:
        transient_lift = args.transient_at + args.transient_duration

    def transient_sample(t, began_flag):
        if args.transient_at is None or t + 1e-9 < args.transient_at:
            return None
        if began_flag[0] == "done":
            return None
        if t > transient_lift + 1e-9:
            began_flag[0] = "done"
            phase = "ended"
        elif began_flag[0] is None:
            began_flag[0] = "down"
            phase = "began"
        else:
            phase = "stationary"
        return {"id": transient_id, "x": transient_pos[0],
                "y": transient_pos[1], "phase": phase}

    began = set()
    transient_state = [None]
    t = 0.0
    end_time = move_end
    last_pos = None
    while t <= end_time + 1e-9:
        touches = []
        pos = positions(t)
        last_pos = pos
        for i in range(n):
            if t + 1e-9 < land_time[i]:
                continue
            x, y = pos[i]
            if i not in began:
                phase = "began"
                began.add(i)
            elif t <= move_start:
                phase = "stationary"
            else:
                phase = "moved"
            touches.append({"id": i + 1, "x": x, "y": y, "phase": phase})
        sample = transient_sample(t, transient_state)
        if sample:
            touches.append(sample)
        if touches:
            frames.append({"t": t0 + t, "w": args.device_width,
                           "h": args.device_height, "touches": touches})
        t += dt

    # Final frame: everyone still down lifts, at the position last
    # reported (recomputing would re-roll jitter and teleport the lift).
    lift = []
    final_pos = last_pos if last_pos is not None else positions(end_time)
    for i in range(n):
        x, y = final_pos[i]
        lift.append({"id": i + 1, "x": x, "y": y, "phase": "ended"})
    if transient_state[0] == "down":
        lift.append({"id": transient_id, "x": transient_pos[0],
                     "y": transient_pos[1], "phase": "ended"})
    frames.append({"t": t0 + end_time + dt, "w": args.device_width,
                   "h": args.device_height, "touches": lift})
    return frames


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="example:\n  %(prog)s --kind swipe --fingers 3 --direction left "
               "--output fixtures/swipe-left-3f.jsonl")
    parser.add_argument("--kind", required=True,
                        choices=["swipe", "pinch", "tap", "wander"],
                        help="gesture to synthesize")
    parser.add_argument("--fingers", type=int, default=2,
                        help="finger count (default: %(default)s)")
    parser.add_argument("--direction", choices=sorted(DIRECTIONS),
                        default="left", help="swipe direction (default: %(default)s)")
    parser.add_argument("--travel", type=float, default=0.25,
                        help="swipe travel, normalized (default: %(default)s)")
    parser.add_argument("--scale-end", type=float, default=1.5,
                        help="pinch end scale, <1 pinches in (default: %(default)s)")
    parser.add_argument("--duration", type=float, default=0.25,
                        help="motion duration in seconds (default: %(default)s)")
    parser.add_argument("--hold", type=float, default=0.08,
                        help="stationary hold after landing, seconds (default: %(default)s)")
    parser.add_argument("--tap-hold", type=float, default=0.04,
                        help="tap: time fingers stay down (default: %(default)s)")
    parser.add_argument("--stagger", type=float, default=0.0,
                        help="landing delay between fingers, seconds (default: %(default)s)")
    parser.add_argument("--rate", type=float, default=90.0,
                        help="frames per second (default: %(default)s)")
    parser.add_argument("--jitter", type=float, default=0.0,
                        help="gaussian position noise, normalized (default: %(default)s)")
    parser.add_argument("--start-radius", type=float, default=40.0,
                        help="finger circle radius in device points (default: %(default)s)")
    parser.add_argument("--device-width", type=float, default=400.0,
                        help="trackpad width in points (default: %(default)s)")
    parser.add_argument("--device-height", type=float, default=240.0,
                        help="trackpad height in points (default: %(default)s)")
    parser.add_argument("--transient-at", type=float, default=None,
                        help="extra transient touch (thumb graze): land time in "
                             "seconds from first landing (default: none)")
    parser.add_argument("--transient-duration", type=float, default=0.08,
                        help="transient touch time on the pad, seconds "
                             "(default: %(default)s)")
    parser.add_argument("--transient-x", type=float, default=0.5,
                        help="transient touch x, normalized (default: %(default)s)")
    parser.add_argument("--transient-y", type=float, default=0.12,
                        help="transient touch y, normalized (default: %(default)s)")
    parser.add_argument("--seed", type=int, default=42,
                        help="jitter RNG seed (default: %(default)s)")
    parser.add_argument("--output", required=True, help="output JSONL path")
    args = parser.parse_args()

    if args.fingers < 1:
        parser.error("--fingers must be >= 1")
    if args.kind == "swipe" and not 0 < args.travel <= 0.9:
        parser.error("--travel must be in (0, 0.9]")
    if args.transient_at is not None and args.transient_at < 0:
        parser.error("--transient-at must be >= 0")
    if args.transient_duration <= 0:
        parser.error("--transient-duration must be > 0")
    if args.rate <= 0:
        parser.error("--rate must be > 0")
    if args.kind == "pinch" and args.scale_end <= 0:
        parser.error("--scale-end must be > 0")

    if args.transient_at is not None:
        last_land = max(i * args.stagger for i in range(args.fingers))
        end = last_land + args.hold + args.duration
        if args.kind == "tap":
            end = last_land + args.tap_hold
        if args.transient_at > end:
            parser.error("--transient-at is past the end of the stream")

    frames = build_frames(args)
    with open(args.output, "w", encoding="utf-8") as f:
        for frame in frames:
            f.write(json.dumps(frame, separators=(",", ":")) + "\n")
    print(f"wrote {len(frames)} frames -> {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
