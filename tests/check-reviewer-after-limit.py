# Usage: check-reviewer-after-limit.py <events.jsonl>. Exit 0 when, after a Codex usage-limit reply,
# an agent whose input mentions review was started and a result came back for it.
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
limit_at = next((i for i, e in enumerate(ev) if e["kind"] == "result" and "usage limit" in e["text"].lower()), None)
if limit_at is None:
    sys.exit(1)
for i, e in enumerate(ev):
    if i > limit_at and e["kind"] == "agent" and "review" in e["text"].lower():
        if any(r["kind"] == "result" and r["id"] == e["id"] and r["text"].strip() for r in ev[i + 1:]):
            sys.exit(0)
sys.exit(1)
