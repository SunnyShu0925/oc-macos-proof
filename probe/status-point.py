import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/win.txt"
best = None
for line in open(path, errors="replace"):
    match = re.search(r"layer=(\d+) rect=([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)", line)
    if not match:
        continue
    layer = int(match.group(1))
    x, y, w, h = (float(match.group(i)) for i in range(2, 6))
    if layer == 25 and w > 0 and h > 0:
        best = (x + w / 2, y + h / 2)
        break
if best is None:
    print("no status window", file=sys.stderr)
    sys.exit(1)
print(int(best[0]), int(best[1]))
