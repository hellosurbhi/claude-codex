# Usage: check-reviewer-after-limit.py <events.jsonl>. Exit 0 when, after a Codex usage-limit reply,
# a review-type agent (subagent_type naming a reviewer) was started and came back with a real,
# non-error, non-acknowledgement result. Implementation agents and launch acknowledgements fail.
import json, re, sys
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
limit_at = next((i for i, e in enumerate(ev) if e["kind"] == "result" and "usage limit" in e["text"].lower()), None)
if limit_at is None:
    sys.exit(1)
ack = re.compile(r"async|background|launched|will be notified|agent .{0,40}not found|no such agent|unavailable", re.I)
for i, e in enumerate(ev):
    if i > limit_at and e["kind"] == "agent":
        try:
            kind = str(json.loads(e["text"]).get("subagent_type", ""))
        except ValueError:
            continue
        if "review" not in kind.lower():
            continue
        for r in ev[i + 1:]:
            if r["kind"] == "result" and r["id"] == e["id"] and not r.get("error") and len(r["text"].strip()) >= 80 and not ack.search(r["text"][:200]):
                sys.exit(0)
sys.exit(1)
