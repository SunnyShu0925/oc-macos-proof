import glob
import os
import re
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else "head"

LEVELS = {"Thinking": ["Off", "Minimal", "Low", "Medium", "High"], "Verbose": ["Off", "On"]}


def read(path):
    try:
        return open(path, errors="replace").read()
    except FileNotFoundError:
        return ""


def marks(text):
    out = {}
    for match in re.finditer(r"ITEM\[\d+\] name=(.*?) markChar=(.*?) mark=(.*?) selected=(.*)", text):
        out[match.group(1).strip()] = match.group(2).strip()
    return out


def checked(text):
    return sorted(name for name, mark in marks(text).items() if mark not in ("<none>", "<missing>", ""))


def dump(name):
    return read("/tmp/ax-%s.txt" % name)


def shot_texts(stage):
    texts = []
    for path in sorted(glob.glob("/tmp/ocr-%s-*.txt" % stage)):
        body = read(path)
        if body.strip():
            texts.append((os.path.basename(path), body))
    return texts


def best_shot(stage, levels):
    scored = []
    for name, body in shot_texts(stage):
        hits = [level for level in levels if re.search(r"\b%s\b" % re.escape(level), body)]
        scored.append((len(hits), name, hits))
    scored.sort(reverse=True)
    return scored[0] if scored else (0, None, [])


fresh = dump("thinking-fresh")
reuse = dump("thinking-reuse")
off = dump("thinking-off")
verbose = dump("verbose-fresh")

for label, text in (("fresh", fresh), ("reuse", reuse), ("off", off), ("verbose", verbose)):
    print("=== %s ===" % label)
    print(text.rstrip())

if "OPEN_MENU=Thinking" not in fresh:
    sys.exit("FAIL: Thinking submenu never opened (fresh)")
if "OPEN_MENU=Thinking" not in reuse:
    sys.exit("FAIL: Thinking submenu never opened (reuse)")
if "OPEN_MENU=Thinking" not in off:
    sys.exit("FAIL: Thinking submenu never opened (explicit Off)")
if "OPEN_MENU=Verbose" not in verbose:
    sys.exit("FAIL: Verbose submenu never opened")

fresh_checked = checked(fresh)
reuse_checked = checked(reuse)
off_checked = checked(off)
verbose_checked = checked(verbose)
print("checked fresh=%r reuse=%r off=%r verbose=%r" % (fresh_checked, reuse_checked, off_checked, verbose_checked))

if MODE == "base":
    if fresh_checked != ["Off"]:
        sys.exit("FAIL: base build should check Off for inherited sessions, saw %r" % (fresh_checked,))
else:
    if fresh_checked:
        sys.exit("FAIL: head build should check nothing for inherited sessions, saw %r" % (fresh_checked,))
    if reuse_checked:
        sys.exit("FAIL: reopened head menu should check nothing, saw %r" % (reuse_checked,))
    if off_checked != ["Off"]:
        sys.exit("FAIL: explicit Off should check Off, saw %r" % (off_checked,))
    if verbose_checked:
        sys.exit("FAIL: inherited Verbose should check nothing, saw %r" % (verbose_checked,))

for stage, levels in (
    ("thinking-fresh", LEVELS["Thinking"]),
    ("thinking-reuse", LEVELS["Thinking"]),
    ("thinking-off", LEVELS["Thinking"]),
    ("verbose-fresh", LEVELS["Verbose"]),
):
    hit_count, best, hits = best_shot(stage, levels)
    print("screenshot %-16s best=%s hits=%r" % (stage, best, hits))
    if hit_count < 3:
        sys.exit("FAIL: no legible menu capture for %s (best %r)" % (stage, best))
    png = "/tmp/shots/%s" % best.replace(".txt", ".png")
    if not os.path.exists(png) or os.path.getsize(png) < 2000:
        sys.exit("FAIL: capture for %s missing or empty" % stage)

print("OK: %s build menu marks and captures match" % MODE)
