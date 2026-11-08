#!/usr/bin/env python3
"""Find a single shipped-window frame that shows rows of two different runs.

The earlier proof scrolled and then trusted a second screenshot. Here the
criterion is read off one bitmap: Vision OCR of the window frame must contain
both turn run ids at the same scroll offset. Expected ids come from the turn
JSON (top-level runId), so the check does not depend on the accessibility tree.

usage: find-both-in-frame.py <probe-dir> <out-dir> <head|base> <turn-a.json> <turn-b.json>
exit 0 only when the mode's claim was observed.
"""

import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import time

MAX_STEPS = 40
TICKS_PER_STEP = 2
TRAIL_AFTER_HIT = 8
RUN_LABEL = re.compile(r"run\s+([0-9a-fA-F][0-9a-fA-F-]{18,})")


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def hex_of(value):
    return re.sub(r"[^0-9a-f]", "", value.lower())


def same_id(expected, candidate):
    a, b = hex_of(expected), hex_of(candidate)
    if not a or not b:
        return False
    return difflib.SequenceMatcher(None, a, b).ratio() >= 0.93


def run_id_from_turn(path):
    data = json.load(open(path))
    value = data.get("runId")
    if not value:
        raise SystemExit("no runId in " + path)
    return value.lower()


def ocr(proof, png):
    return sh(["swift", os.path.join(proof, "ocr-window.swift"), png]).stdout


def window_id(proof):
    out = sh(["swift", os.path.join(proof, "window-capture.swift")]).stdout
    match = re.search(r"^AGENT_EVENTS_WID=(\d+)$", out, re.M)
    return match.group(1) if match else None


def window_rect(proof):
    out = sh(["swift", os.path.join(proof, "window-capture.swift")]).stdout
    match = re.search(r"^AGENT_EVENTS_RECT=(-?\d+),(-?\d+),(\d+),(\d+)$", out, re.M)
    return tuple(int(v) for v in match.groups()) if match else None


def capture(proof, path, wid):
    if not wid:
        return False
    sh(["screencapture", "-x", "-o", "-l", wid, path])
    return os.path.exists(path) and os.path.getsize(path) > 0


def resize(proof):
    script = """
tell application "System Events"
  tell process "OpenClaw"
    set win to window "Agent Events"
    perform action "AXRaise" of win
    set size of win to {1000, 700}
    delay 0.5
    try
      set position of win to {10, 25}
    end try
    delay 0.3
    return "RESIZED=" & (size of win as string)
  end tell
end tell
"""
    return sh(["osascript", "-e", script]).stdout.strip()


def raise_window(proof):
    sh(["osascript", "-e", """
tell application "System Events"
  tell process "OpenClaw"
    perform action "AXRaise" of window "Agent Events"
  end tell
end tell
"""])


def ax_rows(proof):
    result = sh(["osascript", os.path.join(proof, "ax-rows-framed.applescript")])
    return result.stdout or result.stderr


def wheel(proof, rect):
    if not rect:
        return "NO_RECT"
    x0, y0, w, h = rect
    return sh(["swift", os.path.join(proof, "scroll-wheel.swift"),
               str(x0 + w // 2), str(y0 + h // 2), str(TICKS_PER_STEP)]).stdout.strip()


def main():
    proof, outdir, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    old_id = run_id_from_turn(sys.argv[4])
    new_id = run_id_from_turn(sys.argv[5])
    os.makedirs(outdir, exist_ok=True)
    print(resize(proof))
    time.sleep(1.0)
    wid = window_id(proof)
    rect = window_rect(proof)
    print("WID=%s RECT=%s old=%s new=%s" % (wid, rect, old_id, new_id))

    with open(os.path.join(outdir, "ax-start.txt"), "w") as handle:
        handle.write(ax_rows(proof))

    steps = []
    both_frame = None
    both_label = ""
    older_seen_step = None
    newer_seen = False
    frames = 0
    stop_at = None

    for step in range(MAX_STEPS):
        png = os.path.join(outdir, "frame-%02d.png" % step)
        if not capture(proof, png, wid):
            steps.append("step=%d capture-failed" % step)
            time.sleep(0.6)
            continue
        frames += 1
        text = ocr(proof, png)
        with open(os.path.join(outdir, "ocr-step-%02d.txt" % step), "w") as handle:
            handle.write(text)
        tokens = [m.group(1) for m in RUN_LABEL.finditer(text)]
        old_token = next((t for t in tokens if same_id(old_id, t)), None)
        new_token = next((t for t in tokens if same_id(new_id, t)), None)
        newer_seen = newer_seen or new_token is not None
        if old_token is not None and older_seen_step is None:
            older_seen_step = step
        steps.append("step=%d old=%s new=%s tokens=%d" % (
            step, "yes" if old_token else "no", "yes" if new_token else "no", len(tokens)))
        print(steps[-1])

        if old_token and new_token and both_frame is None:
            both_frame = png
            both_label = "run %s | run %s" % (old_token, new_token)
            shutil.copyfile(png, os.path.join(outdir, "both-runs.png"))
            with open(os.path.join(outdir, "both-runs-ocr.txt"), "w") as handle:
                handle.write(text)
            with open(os.path.join(outdir, "ax-hit.txt"), "w") as handle:
                handle.write(ax_rows(proof))
            stop_at = step + TRAIL_AFTER_HIT
            print("HIT both runs in one frame at step %d" % step)

        if not tokens:
            steps.append("step=%d reached empty list" % step)
            break
        if stop_at is not None and step >= stop_at:
            break

        raise_window(proof)
        print(wheel(proof, rect))
        time.sleep(0.4)

    verdict = ["MODE=%s" % mode, "OLD_RUN=%s" % old_id, "NEW_RUN=%s" % new_id,
               "FRAMES=%d" % frames, "NEWER_SEEN=%s" % ("yes" if newer_seen else "no"),
               "OLDER_FIRST_SEEN_STEP=%s" % (older_seen_step if older_seen_step is not None else "-")]
    if both_frame:
        verdict.append("BOTH_RUNS_FRAME=%s" % os.path.basename(both_frame))
        verdict.append("BOTH_RUNS_OCR=%s" % both_label)

    ok = True
    if mode == "head":
        if both_frame is None:
            ok = False
            verdict.append("FAIL=no single frame showed both runs")
        if not newer_seen:
            ok = False
            verdict.append("FAIL=newer run never rendered")
    else:
        if older_seen_step is not None:
            ok = False
            verdict.append("FAIL=older run rendered on the buggy build")
        if not newer_seen:
            ok = False
            verdict.append("FAIL=newer run never rendered")

    with open(os.path.join(outdir, "verdict.txt"), "w") as handle:
        handle.write("\n".join(verdict) + "\n")
    with open(os.path.join(outdir, "steps.txt"), "w") as handle:
        handle.write("\n".join(steps) + "\n")
    print("--- verdict ---")
    print("\n".join(verdict))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
