#!/usr/bin/env bash
# test-checkers.sh: each r11 review finding as a case that must hold. Every case drives the REAL stand-in
# wrapper (or a hand-built log line) and then asks a checker, which reads only the wrapper event log.
# Run: bash tests/test-checkers.sh   (no Claude, no network)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
expect() { local want="$1" name="$2"; shift 2; "$@" >/dev/null 2>&1; local rc=$?; if { [[ $want == pass && $rc -eq 0 ]] || [[ $want == fail && $rc -ne 0 ]]; }; then ok "$name"; else bad "$name (rc=$rc, wanted $want)"; fi; }
mkrun() { rm -rf "$tmp/run"; mkdir -p "$tmp/run/repo"; (cd "$tmp/run/repo" && git init -q && printf 'x=1\n' > app.py); export EVLOG="$tmp/run/wrapper.jsonl" FAKE_LOG="$tmp/run/calls.log"; : > "$EVLOG"; : > "$FAKE_LOG"; unset FAKE_LIMIT FAKE_FAIL_FIRST; export FAKE_ROUNDS=0; }
fake="$here/fake-codex-call.sh"
line() { # wrapper exit phase stdout   -> appends a hand-built event
  python3 - "$EVLOG" "$@" <<'PY'
import json, sys
log, wrapper, code, phase, out = sys.argv[1:6]
n = sum(1 for _ in open(log))
open(log, "a").write(json.dumps({"seq": n + 1, "wrapper": wrapper, "argv": [], "exit": int(code), "resume": None, "thread_id": None, "phase": phase, "stdout": out.replace("\\n", "\n"), "stderr": "", "ts": n + 1}) + "\n")
PY
}
CLEAN='VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n'
LIMIT='codex-call: Codex turn did not complete\nERROR: You have hit your usage limit.\n'

# (r11 a) a tests-only review after the quota hit is not the implementation review.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 tests "$CLEAN"
expect fail "tests-only reviewer after the quota hit is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
line spy 0 implementation "$CLEAN"
expect pass "a later clean implementation review is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
mkrun; line spy 0 implementation "$CLEAN"; line fake 1 unknown "$LIMIT"
expect fail "a review that ran BEFORE the quota hit does not count" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation

# (r11 e) extra finding text after the five clean lines is not clean.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation "${CLEAN}HIGH: add() mishandles floats\n"
expect fail "clean lines followed by extra finding text are rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation 'VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\nAlso: rename x\n'
expect fail "clean lines followed by any extra line are rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation

# (r11 b) a thread id the wrapper never issued (a quoted example in the transcript) cannot seed a resume.
mkrun; cd "$tmp/run/repo"
bash "$fake" --resume 01a1d2dc-5af3-7192-9860-6e8ea8ed1425 "follow up" >/dev/null 2>&1
expect fail "resuming an id the wrapper never issued fails and does not count" python3 "$here/check-resume.py" "$EVLOG"
expect pass "the wrapper refused the unknown thread (exit 1, logged)" test "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; e = wlog.load(sys.argv[2]); print(len(e), e[0]["exit"])' "$here" "$EVLOG")" = "1 1"

# (r11 c) a resume through a shell variable and several wrapper runs in one command are real executions.
mkrun; cd "$tmp/run/repo"
T="$(bash "$fake" "first review" | sed -n 's/^THREAD_ID: //p')"
bash "$fake" --resume "$T" "follow up" >/dev/null 2>&1; bash "$fake" "another thread" >/dev/null 2>&1
expect pass "resume by \$VAR of a wrapper-issued id counts, even with other runs logged" python3 "$here/check-resume.py" "$EVLOG"
expect pass "the resumed call returned the same thread id" test "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; e = wlog.load(sys.argv[2]); print(e[1]["thread_id"] == e[0]["thread_id"] and e[1]["resume"] == e[0]["thread_id"])' "$here" "$EVLOG")" = "True"

# (r11 d) bash -n is not an execution; command and brace-group executions are.
mkrun; cd "$tmp/run/repo"
bash -n "$fake"; bash -n "$fake" --resume abc
expect pass "bash -n never logs" test "$(wc -l < "$EVLOG" | tr -d ' ')" = "0"
T="$(command bash "$fake" "review" | sed -n 's/^THREAD_ID: //p')"
{ bash "$fake" --resume "$T" "again"; } >/dev/null 2>&1
expect pass "command and brace-group executions are logged and resume is found" python3 "$here/check-resume.py" "$EVLOG"
expect pass "exactly the two real executions are logged" test "$(wc -l < "$EVLOG" | tr -d ' ')" = "2"

# clean means exactly the clean block; a resume with two VERDICT lines is not valid.
mkrun; cd "$tmp/run/repo"; export FAKE_ROUNDS=1
bash "$fake" "review" >/dev/null 2>&1
expect pass "the scripted fake's findings reply is not clean" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; sys.exit(1 if wlog.is_clean(wlog.load(sys.argv[2])[0]) else 0)' "$here" "$EVLOG"


# (r12) cases. Each was red against the r11 checkers.
# WHY start time: a review that BEGAN before the quota reply (even if it finished after) is not a reaction to it.
mkrun; python3 - "$EVLOG" <<'PY'
import json, sys
clean = "VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n"
ev = lambda seq, w, code, st, ts, out, ph: {"seq": seq, "wrapper": w, "argv": [], "exit": code, "resume": None, "thread_id": None, "phase": ph, "stdout": out, "stderr": "", "ts_start": st, "ts": ts}
lim = "ERROR: You have hit your usage limit.\n"
open(sys.argv[1], "w").write("\n".join(json.dumps(e) for e in [ev(1, "spy", 0, 5, 20, clean, "implementation"), ev(2, "fake", 1, 9, 10, lim, "unknown")]) + "\n")
PY
expect fail "a review that started before the quota reply but finished after is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
# THREAD_ID text inside a spy reply is extra text, not a transport line.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation "THREAD_ID: abc\n$CLEAN"
expect fail "a THREAD_ID line inside a reviewer reply breaks clean" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
# plan-codex: the clean review must be of the current non-empty plan file.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 plan "$CLEAN"
: > "$tmp/plan.md"
expect fail "an empty plan file never satisfies the plan review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
printf 'the plan\n' > "$tmp/plan.md"
expect fail "a plan that differs from the reviewed input is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
# a real spy run on the plan file logs its sha, which then matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"
printf 'the plan\n' > "$tmp/plan.md"; REVIEW_FAKE=1 SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect pass "spy logs the reviewed plan sha (event carries input_sha256 of the file)" test "$(python3 -c 'import sys,hashlib,json; sys.path.insert(0,sys.argv[1]); import wlog; e=[x for x in wlog.load(sys.argv[2]) if x["wrapper"]=="spy"]; print(bool(e) and e[-1]["input_sha256"]==hashlib.sha256(open(sys.argv[3],"rb").read()).hexdigest())' "$here" "$EVLOG" "$tmp/plan.md")" = "True"
# an id only counts for resume when the earlier reply printed it; a verdict is optional on a follow-up.
mkrun; line fake 0 unknown "no thread line here"
python3 - "$EVLOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
rows[0]["thread_id"] = "t-1"
rows.append({"seq": 2, "wrapper": "fake", "argv": [], "exit": 0, "resume": "t-1", "thread_id": "t-1", "phase": "unknown", "stdout": "THREAD_ID: t-1\nbody\n", "stderr": "", "ts": 2})
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
expect fail "resume of an id the earlier reply never printed is rejected" python3 "$here/check-resume.py" "$EVLOG" --no-verdict
mkrun; T="$(cd "$tmp/run/repo" && bash "$fake" "review" | sed -n 's/^THREAD_ID: //p')"; (cd "$tmp/run/repo" && bash "$fake" --resume "$T" "again" >/dev/null 2>&1)
expect pass "--no-verdict accepts a follow-up with or without a valid verdict" python3 "$here/check-resume.py" "$EVLOG" --no-verdict
# unique thread ids even for calls made in the same instant.
mkrun; cd "$tmp/run/repo"; bash "$fake" a >/dev/null 2>&1 & bash "$fake" b >/dev/null 2>&1 & wait
expect pass "concurrent wrapper runs get distinct seq and distinct thread ids" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2]); print(len({x["seq"] for x in e})==2 and len({x["thread_id"] for x in e})==2)' "$here" "$EVLOG")" = "True"

exit $fail
