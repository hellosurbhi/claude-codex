# Usage: check-final-review.py <wrapper.jsonl>. Exit 0 only when the FINAL real Codex wrapper execution (by start time) exited 0 and its output is `clean` under
# wlog.verdict_state, so a reported APPROVED agrees with the last reviewer result in the log.
# WHY (cc11-main-r8 change B): the real scenario used to accept any valid historical verdict plus a resume and then trust the agent's own APPROVED status line, so a final BLOCKED
# review, or a later failed call, could still pass. The last call decides: an earlier clean review never carries forward, and no call may follow the clean one.
import sys
import wlog
evs = sorted((e for e in wlog.load(sys.argv[1]) if wlog.is_real(e)), key=lambda x: x.get("ts_start", x["ts"]))
if not evs:
    print("no real reviewer call in the log"); sys.exit(1)
last = evs[-1]
if not wlog.is_clean(last):
    print("the final real reviewer call (exit %s) is not a clean verdict: %r" % (last["exit"], wlog.reply_text(last)[:120])); sys.exit(1)
sys.exit(0)
