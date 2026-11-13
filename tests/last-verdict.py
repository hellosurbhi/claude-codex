# Usage: last-verdict.py <events.jsonl>. Prints the verdict of the LAST codex-call.sh execution's
# reply (paired by tool_use_id): its single valid VERDICT, or NONE when that call failed or had
# no single valid verdict (an earlier verdict is never carried forward).
import json, re, sys
from evlib import wrapper_runs
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
res = {e["id"]: e["text"] for e in ev if e["kind"] == "result"}
last = "NONE"
for e in ev:
    if e["kind"] == "cmd" and wrapper_runs(e["text"]):
        out = res.get(e["id"], "")
        lines = re.findall(r"^VERDICT:.*$", out, re.M)
        m = re.fullmatch(r"VERDICT: (APPROVED|WARNING|BLOCKED|CLEAN|FINDINGS)\s*", lines[0]) if len(lines) == 1 else None
        last = m.group(1) if m else "NONE"
print(last)
