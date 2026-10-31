import json
import re
import sys

raw = open("/tmp/devices-before.json", errors="replace").read()
match = re.search(r"\{.*\}", raw, re.S)
parsed = json.loads(match.group(0)) if match else {}
for pending in parsed.get("pending", []) or []:
    rid = pending.get("requestId") or pending.get("id")
    if rid:
        print(rid)
