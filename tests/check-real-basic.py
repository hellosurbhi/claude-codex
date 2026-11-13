# Usage: check-real-basic.py <wrapper.jsonl> thread|verdict. Exit 0 when a Codex wrapper execution
# exited 0 and returned a THREAD_ID line (thread) or a single valid VERDICT (verdict).
import re, sys
import wlog
# WHY only wrapper == real: the fake and the spy reviewer also write THREAD_ID and VERDICT lines, so unfiltered they would
# satisfy an assertion that claims real Codex evidence (r25b).
evs = [e for e in wlog.load(sys.argv[1]) if e["wrapper"] == "real"]
if sys.argv[2] == "thread":
    ok = any(e["exit"] == 0 and re.search(r"^THREAD_ID: [0-9a-f-]{8,}", e["stdout"], re.M) for e in evs)
else:
    ok = any(wlog.valid_verdict(e) for e in evs)
sys.exit(0 if ok else 1)
