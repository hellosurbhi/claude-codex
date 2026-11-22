# Usage: check-scripted.py <wrapper.jsonl> rounds <N> | final <state> [--impl] [--real] | failfirst <N>
# Scripted-reviewer scenarios, asserted on the wrapper event log only (never calls.log: a call that dies before it
# writes calls.log, such as a resume of an unknown thread, must not leave an earlier CLEAN standing; r17).
import sys
import wlog
# WHY ordered by START time: a slow older call that finishes after a newer one must not become "the last word" (r18).
# WHY --real selects the genuine wrapper events instead of the fake (r9 finding 1): the real scenario is bound to the final state and phase by this SAME mechanism, using the state and impl the shim
# records in each real event's meta; a real event has no scripted result, so the clean verdict comes from wlog.is_clean alone.
REAL = "--real" in sys.argv
evs = sorted((e for e in wlog.load(sys.argv[1]) if (wlog.is_real(e) if REAL else e["wrapper"] == "fake")), key=lambda e: e.get("ts_start", e["ts"]))
mode = sys.argv[2]
if mode == "rounds":
    # finding rounds 1..N each appeared as a real reply, in order, as the subsequence of the reviewer's replies
    k = 0
    for e in evs:
        if e["exit"] == 0 and e.get("meta", {}).get("round") == str(k + 1):
            k += 1
    sys.exit(0 if k == int(sys.argv[3]) else 1)
if mode == "final":
    # the LAST execution is a clean reply, given for the state the run ended in (and, with --impl, after add() existed)
    if not evs:
        sys.exit(1)
    last = evs[-1]
    m = last.get("meta", {})
    ok = last["exit"] == 0 and wlog.is_clean(last) and (REAL or m.get("result") == "CLEAN") and m.get("state") == sys.argv[3]
    if "--impl" in sys.argv:
        ok = ok and m.get("impl") == "yes"
    sys.exit(0 if ok else 1)
if mode == "failfirst":
    n = int(sys.argv[3])
    # the first N executions returned no valid verdict, the very next one did, and every later one did too
    bad = [wlog.valid_verdict(e) is None for e in evs]
    sys.exit(0 if len(evs) > n and all(bad[:n]) and not any(bad[n:]) else 1)
sys.exit(2)
