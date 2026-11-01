import glob
import os
import re
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else "head"

LEVELS = {
    "Thinking": ["Off", "Minimal", "Low", "Medium", "High"],
    "Verbose": ["Off", "On"],
}
STAGES = [
    ("thinking-fresh", "Thinking"),
    ("thinking-off", "Thinking"),
    ("verbose-fresh", "Verbose"),
]


def read(path):
    try:
        return open(path, errors="replace").read()
    except FileNotFoundError:
        return ""


def states(stage):
    out = {}
    for match in re.finditer(r"ITEM name=(.*?) state=(\d+)", read("/tmp/state-%s.txt" % stage)):
        out[match.group(1).strip()] = int(match.group(2))
    return out


def ocr_texts(stage):
    texts = []
    for path in sorted(glob.glob("/tmp/ocr-%s-*.txt" % stage)):
        body = read(path)
        if body.strip():
            texts.append((os.path.basename(path), body))
    return texts


def best_shot(stage, levels):
    scored = []
    for name, body in ocr_texts(stage):
        hits = [level for level in levels if re.search(r"\b%s\b" % re.escape(level), body)]
        scored.append((len(hits), name, hits))
    scored.sort(reverse=True)
    return scored[0] if scored else (0, None, [])


fresh = states("thinking-fresh")
off = states("thinking-off")
verbose = states("verbose-fresh")

for label in ("root", "thinking-fresh", "thinking-off", "verbose-fresh"):
    print("=== %s ===" % label)
    print(read("/tmp/state-%s.txt" % label).rstrip())

if not fresh:
    sys.exit("FAIL: no Thinking submenu state recorded (fresh)")
if not off:
    sys.exit("FAIL: no Thinking submenu state recorded (explicit Off)")
if not verbose:
    sys.exit("FAIL: no Verbose submenu state recorded")

fresh_on = sorted(name for name, state in fresh.items() if state != 0)
off_on = sorted(name for name, state in off.items() if state != 0)
verbose_on = sorted(name for name, state in verbose.items() if state != 0)
print("on fresh=%r off=%r verbose=%r" % (fresh_on, off_on, verbose_on))

if MODE == "base":
    if fresh_on != ["Off"]:
        sys.exit("FAIL: base build should mark Off for inherited Thinking, saw %r" % (fresh_on,))
    if verbose_on != ["Off"]:
        sys.exit("FAIL: base build should mark Off for inherited Verbose, saw %r" % (verbose_on,))
else:
    if fresh_on:
        sys.exit("FAIL: head build should mark nothing for inherited Thinking, saw %r" % (fresh_on,))
    if verbose_on:
        sys.exit("FAIL: head build should mark nothing for inherited Verbose, saw %r" % (verbose_on,))

if off_on != ["Off"]:
    sys.exit("FAIL: explicit Off should mark Off, saw %r" % (off_on,))

for stage, title in STAGES:
    hit_count, best, hits = best_shot(stage, LEVELS[title])
    print("screenshot %-16s best=%s hits=%r" % (stage, best, hits))
    if hit_count < 3:
        sys.exit("FAIL: no legible %s capture for %s (best %r)" % (title, stage, best))
    png = "/tmp/shots/%s" % best.replace(".txt", ".png")
    if not os.path.exists(png) or os.path.getsize(png) < 2000:
        sys.exit("FAIL: capture for %s missing or empty" % stage)

print("OK: %s build menu marks and captures match" % MODE)
