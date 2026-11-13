# Usage: last-verdict.py <wrapper.jsonl>. Prints the verdict of the LAST Codex wrapper execution:
# its single valid VERDICT, or NONE when that call failed or had no single valid verdict (an
# earlier verdict is never carried forward).
import sys
import wlog
last = "NONE"
for e in wlog.load(sys.argv[1]):
    if e["wrapper"] in ("fake", "real"):
        last = wlog.valid_verdict(e) or "NONE"
print(last)
