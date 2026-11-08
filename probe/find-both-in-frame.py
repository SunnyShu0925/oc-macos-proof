#!/usr/bin/env python3
"""Find one shipped-window frame that shows rows of two different runs.

The proof has to be readable off a single bitmap: Vision OCR of the window frame
must contain both turn run ids at the same scroll offset. Expected ids come from
the turn JSON (top-level runId), so the check does not depend on the
accessibility tree.

usage: find-both-in-frame.py <probe-dir> <out-dir> <head|base> <turn-a> <turn-b> [app-path]
exit 0 only when the mode's claim was observed.
"""

import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

MAX_STEPS = 26
TICKS_PER_STEP = 6
RUN_LABEL = re.compile(r"run\s+([0-9a-fA-F][0-9a-fA-F-]{18,})")


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def hex_of(value):
    return re.sub(r"[^0-9a-f]", "", value.lower())


def same_id(expected, candidate):
    a, b = hex_of(expected), hex_of(candidate)
    return bool(a and b) and difflib.SequenceMatcher(None, a, b).ratio() >= 0.93


def run_id_from_turn(path):
    data = json.load(open(path))
    value = data.get("runId")
    if not value:
        raise SystemExit("no runId in " + path)
    return value.lower()


def ocr(proof, png):
    return sh(["swift", os.path.join(proof, "ocr-window.swift"), png]).stdout


def window_probe(proof):
    out = sh(["swift", os.path.join(proof, "window-capture.swift")]).stdout
    wid = re.search(r"^AGENT_EVENTS_WID=(\d+)$", out, re.M)
    rect = re.search(r"^AGENT_EVENTS_RECT=(-?\d+),(-?\d+),(\d+),(\d+)$", out, re.M)
    return (wid.group(1) if wid else None, tuple(int(v) for v in rect.groups()) if rect else None)


def capture(path, wid):
    if not wid:
        return False
    sh(["screencapture", "-x", "-o", "-l", wid, path])
    return os.path.exists(path) and os.path.getsize(path) > 0


def digest(path):
    with open(path, "rb") as handle:
        return hashlib.md5(handle.read()).hexdigest()


def osa(script):
    return sh(["osascript", "-e", script]).stdout.strip()


def resize_window():
    return osa("""
tell application "System Events"
  tell process "OpenClaw"
    set win to window "Agent Events"
    perform action "AXRaise" of win
    set size of win to {1000, 700}
    delay 0.4
    try
      set position of win to {10, 25}
    end try
    delay 0.2
    return "RESIZED=" & (size of win as string) & " FOCUSED=" & (value of attribute "AXFocused" of win as string) & " MAIN=" & (value of attribute "AXMain" of win as string)
  end tell
end tell
""")


def focus_state():
    return osa("""
tell application "System Events"
  tell process "OpenClaw"
    set win to window "Agent Events"
    return "FOCUSED=" & (value of attribute "AXFocused" of win as string) & " MAIN=" & (value of attribute "AXMain" of win as string)
  end tell
end tell
""")


def click(proof, point):
    return sh(["swift", os.path.join(proof, "click-at.swift"),
               str(point[0]), str(point[1])]).stdout.strip()


def wheel(proof, point, ticks):
    return sh(["swift", os.path.join(proof, "scroll-wheel.swift"),
               str(point[0]), str(point[1]), str(ticks)]).stdout.strip()


def ax_rows(proof):
    result = sh(["osascript", os.path.join(proof, "ax-rows-framed.applescript")])
    return result.stdout or result.stderr


def main():
    proof, outdir, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    old_id = run_id_from_turn(sys.argv[4])
    new_id = run_id_from_turn(sys.argv[5])
    app_path = sys.argv[6] if len(sys.argv) > 6 else None
    os.makedirs(outdir, exist_ok=True)

    print(resize_window())
    if app_path:
        sh(["open", "-a", app_path])
        time.sleep(2.0)
    time.sleep(0.8)
    wid, rect = window_probe(proof)
    print("WID=%s RECT=%s" % (wid, rect))
    if not rect:
        raise SystemExit("no Agent Events window")
    point = (rect[0] + rect[2] // 2, rect[1] + rect[3] // 2)
    print(click(proof, point))
    print("AFTER_CLICK " + focus_state())
    time.sleep(0.5)

    with open(os.path.join(outdir, "ax-start.txt"), "w") as handle:
        handle.write(ax_rows(proof))

    steps = []
    both_frame = None
    both_label = ""
    older_seen_step = None
    newer_seen = False
    frames = 0
    stale = 0
    previous = None

    for step in range(MAX_STEPS):
        png = os.path.join(outdir, "frame-%02d.png" % step)
        if not capture(png, wid):
            steps.append("step=%d capture-failed" % step)
            continue
        frames += 1
        now = digest(png)
        if previous is not None and now == previous:
            stale += 1
            if stale == 4:
                steps.append("step=%d scroll leaves the frame unchanged" % step)
        else:
            stale = 0
        previous = now
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
            print("HIT both runs in one frame at step %d" % step)
            break

        if not tokens:
            steps.append("step=%d reached empty list" % step)
            break

        print(wheel(proof, point, TICKS_PER_STEP))
        time.sleep(0.45)

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
