# Usage: check-scripted.py <wrapper.jsonl> rounds <N> | final <state> [--impl] [--real] | failfirst <N>
# Scripted-reviewer scenarios, asserted on the wrapper event log only (never calls.log: a call that dies before it
# writes calls.log, such as a resume of an unknown thread, must not leave an earlier CLEAN standing; r17).
import sys
import wlog
# WHY ordered by START time: a slow older call that finishes after a newer one must not become "the last word" (r18).
# WHY --real selects the genuine wrapper events instead of the fake (r9 finding 1): the real scenario is bound to the final state and phase by this SAME mechanism, using the state and impl the shim
# records in each real event's meta; a real event has no scripted result, so the clean verdict comes from wlog.is_clean alone.
REAL = "--real" in sys.argv
# WHY wrapper-failed events join the real list (r23): an early exit of the real wrapper (bad arguments, a missing prompt file) never reaches the shim, so without its own event an earlier clean review stood as the last word.
# They have exit != 0 and no verdict, so every mode below reads them as a failed attempt.
evs = sorted((e for e in wlog.load(sys.argv[1]) if ((wlog.is_real(e) or wlog.is_wrapper_failure(e)) if REAL else e["wrapper"] == "fake")), key=lambda e: e.get("ts_start", e["ts"]))
mode = sys.argv[2]
if mode == "rounds":
    # finding rounds 1..N each appeared as a real reply, in order, as the subsequence of the reviewer's replies
    k = 0
    for e in evs:
        if e["exit"] == 0 and e.get("meta", {}).get("round") == str(k + 1):
            k += 1
    if k != int(sys.argv[3]):
        print("REJECT: finding rounds 1..%s did not all appear in order (reached %d)" % (sys.argv[3], k), file=sys.stderr)
    sys.exit(0 if k == int(sys.argv[3]) else 1)
if mode == "final" and "--audit" in sys.argv:
    # tdd-execute-codex (r10 finding 2, r11 finding 2): Codex only AUDITS the tests there (a Claude agent reviews the implementation). The LATEST audit attempt must
    # have exited 0 with a clean verdict (APPROVED, zero findings) and recorded the state it audited. An audit attempt is a call the shim marked audit=yes at call time
    # (it asked for the read-only sandbox); implementation calls are marked audit=no and are skipped, whatever they returned.
    # WHY marked at call time and not "has a verdict": a failed or malformed re-audit has no valid verdict, so filtering by verdict dropped it and left an earlier clean audit standing.
    # WHY not bound to the final state: the implementation legitimately changes the files after the audit; the final review is the review record's job.
    a = [e for e in evs if e.get("meta", {}).get("audit") == "yes"]
    # WHY start == end state (r13 finding 2): a file edited while the audit ran must not inherit the audit's approval.
    am = a[-1].get("meta", {}) if a else {}
    good = bool(a and a[-1]["exit"] == 0 and wlog.is_clean(a[-1]) and am.get("state") and am.get("endstate") == am.get("state"))
    # WHY a wrapper-failed event after the last audit voids it (r23): an early exit of the real wrapper carries no sandbox, so it cannot be told from a failed re-audit; failing closed costs one re-audit.
    if good and any(e["wrapper"] == "wrapper-failed" and e.get("ts_start", e["ts"]) > a[-1].get("ts_start", a[-1]["ts"]) for e in evs):
        good = False
    if not good:
        print("REJECT: the last test audit is %s" % ("missing" if not a else "not a clean exit-0 verdict bound to one state"), file=sys.stderr)
    sys.exit(0 if good else 1)
if mode == "final":
    # the LAST execution is a clean reply, given for the state the run ended in (and, with --impl, after add() existed)
    if not evs:
        print("REJECT: no reviewer execution in the log", file=sys.stderr); sys.exit(1)
    last = evs[-1]
    m = last.get("meta", {})
    ok = last["exit"] == 0 and wlog.is_clean(last) and (REAL or m.get("result") == "CLEAN") and m.get("state") == sys.argv[3]
    # WHY start state == verdict state == final state for a real call (r13 finding 2): the shim records `state` when the call STARTS and `endstate` when it returns; an edit made while the
    # reviewer ran changes the tree it judged, so an approval whose two states differ is void. The fake has no such window.
    if REAL:
        ok = ok and m.get("endstate") == m.get("state")
    if "--impl" in sys.argv:
        ok = ok and m.get("impl") == "yes"
    if not ok:
        print("REJECT: the last execution is not a clean verdict for the final state%s" % (" with a stable start and verdict state" if REAL else ""), file=sys.stderr)
    sys.exit(0 if ok else 1)
if mode == "failfirst":
    n = int(sys.argv[3])
    # the first N executions returned no valid verdict, the very next one did, and every later one did too
    bad = [wlog.valid_verdict(e) is None for e in evs]
    good = len(evs) > n and all(bad[:n]) and not any(bad[n:])
    if not good:
        print("REJECT: the first %d executions were not all invalid followed only by valid ones" % n, file=sys.stderr)
    sys.exit(0 if good else 1)
sys.exit(2)
