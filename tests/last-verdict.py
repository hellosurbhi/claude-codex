# Usage: last-verdict.py <wrapper.jsonl>. Prints the verdict of the LAST Codex wrapper execution:
# its single valid VERDICT, or NONE when that call failed or had no single valid verdict (an
# earlier verdict is never carried forward).
import sys
import wlog
# WHY the shared decision (r25): the last attempt of ANY kind decides, so a failed attempt of another kind (wrapper-failed, a fallback reviewer) is the last word too.
evs = wlog.load(sys.argv[1])
last = wlog.final_review_state(evs)["last"]
print((wlog.valid_verdict(last) or "NONE") if last is not None else "NONE")
