#!/usr/bin/env python3
"""Scroll the shipped Agent Events window until both runs share one visible viewport.

The window is driven only through AppKit accessibility reads plus real wheel
events (what a person does), because SwiftUI ScrollView ignores AX scrollbar
writes and forwarded page keys. A run counts as visible only when its row label
frame sits fully inside the AXScrollArea viewport, so the captured bitmap cannot
be explained away as an off-screen row.

usage: find-visible-runs.py <probe-dir> <out-dir> <head|base>
exit 0 only when the mode's claim was observed.
"""

import os
import re
import subprocess
import sys
import time

MAX_STEPS = 40
TICKS_PER_STEP = 2
MAX_FRAMES = 30
RUN_LABEL = re.compile(r"^run ([0-9a-f][0-9a-f-]{7,})$")


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def probe(proof):
    return sh(["osascript", os.path.join(proof, "ax-rows-framed.applescript")]).stdout


def parse(text):
    win = scroll = None
    rows = []
    for line in text.splitlines():
        if line.startswith("WIN "):
            win = tuple(float(v) for v in line.split()[1:5])
        elif line.startswith("SCROLL "):
            scroll = tuple(float(v) for v in line.split()[1:5])
        elif line.startswith("ROW "):
            parts = line.split(" ", 5)
            if len(parts) == 6:
                rows.append((tuple(float(v) for v in parts[1:5]), parts[5]))
    return win, scroll, rows


def run_id(label):
    match = RUN_LABEL.match(label.strip())
    return match.group(1) if match else None


def inside(rect, clip, tol=2.0):
    x, y, w, h = rect
    cx, cy, cw, ch = clip
    return x >= cx - tol and y >= cy - tol and x + w <= cx + cw + tol and y + h <= cy + ch + tol


def rect_text(rect):
    return "%d,%d %dx%d" % tuple(int(round(v)) for v in rect)


def window_id(proof):
    out = sh(["swift", os.path.join(proof, "window-capture.swift")]).stdout
    match = re.search(r"^AGENT_EVENTS_WID=(\d+)$", out, re.M)
    return match.group(1) if match else None


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
    delay 0.6
    try
      set position of win to {10, 25}
    end try
    delay 0.4
    return "RESIZED=" & (size of win as string) & " POS=" & (position of win as string)
  end tell
end tell
"""
    return sh(["osascript", "-e", script]).stdout.strip()


def raise_window(proof):
    script = """
tell application "System Events"
  tell process "OpenClaw"
    perform action "AXRaise" of window "Agent Events"
  end tell
end tell
"""
    sh(["osascript", "-e", script])


def wheel(proof, clip):
    x = int(clip[0] + clip[2] / 2)
    y = int(clip[1] + clip[3] / 2)
    return sh(["swift", os.path.join(proof, "scroll-wheel.swift"), str(x), str(y), str(TICKS_PER_STEP)]).stdout.strip()


def main():
    proof, outdir, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(outdir, exist_ok=True)
    print(resize(proof))
    time.sleep(0.8)
    wid = window_id(proof)
    print("WID=%s" % wid)

    steps = []
    tree_ids = set()
    max_visible = 0
    hit = None
    hit_lines = []
    frames = 0
    last_clip = None
    empty_streak = 0

    for step in range(MAX_STEPS):
        dump = probe(proof)
        with open(os.path.join(outdir, "ax-step-%02d.txt" % step), "w") as handle:
            handle.write(dump)
        win, scroll, rows = parse(dump)
        ids = set()
        for _, label in rows:
            rid = run_id(label)
            if rid:
                ids.add(rid)
        tree_ids |= ids
        if scroll is None:
            steps.append("step=%d no-scroll-area win=%s" % (step, rect_text(win) if win else "-"))
            time.sleep(0.6)
            continue
        last_clip = scroll
        visible = []
        for rect, label in rows:
            rid = run_id(label)
            if rid and inside(rect, scroll):
                visible.append((rect, rid))
        visible_ids = {rid for _, rid in visible}
        max_visible = max(max_visible, len(visible_ids))
        steps.append("step=%d scroll=%s visible=%s tree=%s" % (
            step, rect_text(scroll), ",".join(sorted(visible_ids)) or "-",
            ",".join(sorted(ids)) or "-"))
        print(steps[-1])

        if frames < MAX_FRAMES:
            if capture(proof, os.path.join(outdir, "frame-%02d.png" % step), wid):
                frames += 1

        if mode == "head" and len(visible_ids) >= 2 and hit is None:
            hit = step
            capture(proof, os.path.join(outdir, "both-runs.png"), wid)
            with open(os.path.join(outdir, "ax-hit.txt"), "w") as handle:
                handle.write(dump)
            hit_lines = ["visible row %s frame=%s inside viewport %s" % (
                rid, rect_text(rect), rect_text(scroll)) for rect, rid in visible]

        if visible_ids:
            empty_streak = 0
        else:
            empty_streak += 1
            if empty_streak >= 2:
                steps.append("end-of-list after step=%d" % step)
                break

        raise_window(proof)
        print(wheel(proof, scroll))
        time.sleep(0.45)

    if mode == "base":
        if last_clip is not None:
            raise_window(proof)
            wheel(proof, last_clip)
            time.sleep(0.6)
            capture(proof, os.path.join(outdir, "base-bottom.png"), wid)

    verdict = ["MODE=%s" % mode, "TREE_IDS=%s" % (",".join(sorted(tree_ids)) or "-"),
               "MAX_VISIBLE_IDS=%d" % max_visible, "FRAMES=%d" % frames]
    if hit is not None:
        verdict.append("HIT_STEP=%d" % hit)
    verdict.extend(hit_lines)

    ok = True
    if mode == "head":
        if hit is None:
            ok = False
            verdict.append("FAIL=never saw both runs inside one viewport")
        if len(tree_ids) < 2:
            ok = False
            verdict.append("FAIL=window tree holds %d run id(s), expected 2" % len(tree_ids))
    else:
        if len(tree_ids) != 1:
            ok = False
            verdict.append("FAIL=window tree holds %d run id(s), expected 1" % len(tree_ids))
        if max_visible > 1:
            ok = False
            verdict.append("FAIL=more than one run ever visible on the buggy build")

    with open(os.path.join(outdir, "verdict.txt"), "w") as handle:
        handle.write("\n".join(verdict) + "\n")
    with open(os.path.join(outdir, "steps.txt"), "w") as handle:
        handle.write("\n".join(steps) + "\n")
    print("--- verdict ---")
    print("\n".join(verdict))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
