# Usage: check-resume.py <events.jsonl>. Exit 0 when a --resume call (line continuations and quoted
# ids allowed) actually EXECUTED codex-call.sh and returned, by its own tool_use_id, exactly the
# thread id an EARLIER non-resume execution created, with exactly one VERDICT line, which is valid.
import json, re, sys
from evlib import wrapper_runs, resume_id
noverdict = "--no-verdict" in sys.argv
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
res = {e["id"]: (e["text"] if not e.get("error") else "") for e in ev if e["kind"] == "result"}
initial, ok = set(), False
for e in ev:
    if e["kind"] != "cmd":
        continue
    runs = wrapper_runs(e["text"])
    if len(runs) != 1:
        continue
    rid = resume_id(runs[0])
    out = res.get(e["id"], "")
    tids = re.findall(r"THREAD_ID: ([0-9a-f-]{8,})", out)
    if rid is None:
        initial.update(tids)
        continue
    verds = re.findall(r"^VERDICT:.*$", out, re.M)
    valid = (len(verds) == 0 and bool(out.strip()) or len(verds) == 1 and bool(re.fullmatch(r"VERDICT: (APPROVED|WARNING|BLOCKED|CLEAN|FINDINGS)\s*", verds[0]))) if noverdict else (len(verds) == 1 and re.fullmatch(r"VERDICT: (APPROVED|WARNING|BLOCKED|CLEAN|FINDINGS)\s*", verds[0]))
    if rid in initial and tids == [rid] and valid:
        ok = True
sys.exit(0 if ok else 1)
