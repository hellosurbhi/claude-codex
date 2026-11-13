# Usage: check-reviewer-after-limit.py <events.jsonl>. Exit 0 when, AFTER a codex-call.sh execution
# whose own reply reported the usage limit, a review-typed agent (subagent_type naming a reviewer)
# was started and returned a non-error reply with exactly one valid verdict line, as the skills require.
import json, re, sys
from evlib import first_limit_cmd_index
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
limit_at = first_limit_cmd_index(ev)
if limit_at is None:
    sys.exit(1)
for i, e in enumerate(ev):
    if i > limit_at and e["kind"] == "agent":
        try:
            kind = str(json.loads(e["text"]).get("subagent_type", ""))
        except ValueError:
            continue
        if "review" not in kind.lower():
            continue
        for r in ev[i + 1:]:
            if r["kind"] == "result" and r["id"] == e["id"] and not r.get("error"):
                lines = re.findall(r"^VERDICT:.*$", r["text"], re.M)
                if len(lines) == 1 and re.fullmatch(r"VERDICT: (APPROVED|WARNING|BLOCKED)\s*", lines[0]):
                    sys.exit(0)
sys.exit(1)
