# Usage: check-reviewer-after-limit.py <events.jsonl>. Exit 0 when, AFTER the reply of a
# codex-call.sh execution that reported the usage limit, a review-typed agent (subagent_type naming
# a reviewer) was started and the LAST such review came back clean: a non-error reply with exactly
# one valid verdict line, APPROVED, and CRITICAL/HIGH/MEDIUM/LOW all "none". An earlier approval
# followed by a failed or blocked review does not pass.
import json, re, sys
from evlib import first_limit_cmd_index
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
limit_at = first_limit_cmd_index(ev)
if limit_at is None:
    sys.exit(1)
last_ok = None
for i, e in enumerate(ev):
    if i > limit_at and e["kind"] == "agent":
        try:
            kind = str(json.loads(e["text"]).get("subagent_type", ""))
        except ValueError:
            continue
        if "review" not in kind.lower():
            continue
        ok = False
        for r in ev[i + 1:]:
            if r["kind"] == "result" and r["id"] == e["id"] and not r.get("error"):
                t = r["text"]
                lines = re.findall(r"^VERDICT:.*$", t, re.M)
                sev = re.findall(r"^(CRITICAL|HIGH|MEDIUM|LOW): none\s*$", t, re.M)
                allsev = re.findall(r"^\s*(?:CRITICAL|HIGH|MEDIUM|LOW)\b.*$", t, re.M | re.I)
                ok = len(allsev) == 4 and len(lines) == 1 and re.fullmatch(r"VERDICT: APPROVED\s*", lines[0]) is not None and sorted(sev) == ["CRITICAL", "HIGH", "LOW", "MEDIUM"]
        last_ok = ok
sys.exit(0 if last_ok else 1)
