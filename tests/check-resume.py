# Usage: check-resume.py <events.jsonl>. Exit 0 when a --resume call (line continuations and quoted
# ids allowed) returned, by its own tool_use_id, exactly the thread id an EARLIER non-resume
# codex-call.sh call created, with exactly one VERDICT line in its reply and that verdict valid.
import json, re, sys
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
res = {e["id"]: e["text"] for e in ev if e["kind"] == "result"}
initial, ok = set(), False
for e in ev:
    if e["kind"] != "cmd" or "codex-call.sh" not in e["text"]:
        continue
    cmd = re.sub(r"\\\n\s*", " ", e["text"])
    out = res.get(e["id"], "")
    m = re.search(r"--resume[ =][\"']?([0-9a-f-]{8,})", cmd)
    if not m:
        initial.update(re.findall(r"THREAD_ID: ([0-9a-f-]{8,})", out))
        continue
    tids = re.findall(r"THREAD_ID: ([0-9a-f-]{8,})", out)
    verds = re.findall(r"^VERDICT:.*$", out, re.M)
    if m.group(1) in initial and tids == [m.group(1)] and len(verds) == 1 and re.fullmatch(r"VERDICT: (APPROVED|WARNING|BLOCKED|CLEAN|FINDINGS)\s*", verds[0]):
        ok = True
sys.exit(0 if ok else 1)
