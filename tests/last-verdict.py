# Usage: last-verdict.py <wrapper.jsonl>. Prints the verdict of the LAST Codex wrapper execution:
# its single valid VERDICT, or NONE when that call failed or had no single valid verdict (an
# earlier verdict is never carried forward).
import sys
import wlog
last = "NONE"
# WHY order by START time: the log is appended in completion order, so a slower older review must not override a newer one (r15).
for e in sorted(wlog.load(sys.argv[1]), key=lambda x: x.get("ts_start", x["ts"])):
    if e["wrapper"] in ("fake", "real"):
        last = wlog.valid_verdict(e) or "NONE"
    # WHY a wrapper-failed event is a failed attempt (r23): the wrapper exited before it reached codex, so the earlier verdict must not stand.
    elif wlog.is_wrapper_failure(e):
        last = "NONE"
print(last)
