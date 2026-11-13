# Usage: last-verdict.py <events.jsonl>. Prints the verdict of the last codex-call.sh reply (the
# result paired to a codex-call.sh command by tool_use_id), or NONE.
import json, re, sys
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
res = {e["id"]: e["text"] for e in ev if e["kind"] == "result"}
last = "NONE"
for e in ev:
    if e["kind"] == "cmd" and "codex-call.sh" in e["text"]:
        m = re.findall(r"^VERDICT: (APPROVED|WARNING|BLOCKED|CLEAN|FINDINGS)\s*$", res.get(e["id"], ""), re.M)
        if len(m) == 1:
            last = m[0]
print(last)
