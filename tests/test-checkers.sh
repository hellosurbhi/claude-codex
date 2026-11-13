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
gdiff() { local f; for f in "$@"; do git diff --no-index --no-color /dev/null "$f"; done; }
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


# Offline stand-ins: a `claude` that always approves (spy-reviewer.sh calls `claude -p`), and a `codex` for the shim.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\n[[ -n "${EDIT_DURING:-}" ]] && printf "edited while reviewing\\n" >> "$EDIT_DURING"\nprintf "VERDICT: APPROVED\\n"\n' > "$tmp/bin/claude"; chmod +x "$tmp/bin/claude"
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
printf 'the plan\n' > "$tmp/plan.md"; PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
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


# (r14) cases. Each was red against the c54ad0d checkers and wrappers.
# reviewer.sh returns a clean approval as ONE line; that must count as clean, and CLEAN/FINDINGS are not verdicts.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation 'VERDICT: APPROVED\n'
expect pass "the one-line reviewer.sh approval counts as clean" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
mkrun; line fake 0 unknown 'THREAD_ID: t\nVERDICT: CLEAN\n'
expect fail "VERDICT: CLEAN is not a valid verdict" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; sys.exit(0 if wlog.valid_verdict(wlog.load(sys.argv[2])[0]) else 1)' "$here" "$EVLOG"
# the LAST review by start time decides, even when an older review finished later.
mkrun; python3 - "$EVLOG" <<'PY'
import json, sys
ev = lambda seq, w, code, st, ts, out: {"seq": seq, "wrapper": w, "argv": [], "exit": code, "resume": None, "thread_id": None, "phase": "implementation", "stdout": out, "stderr": "", "ts_start": st, "ts": ts}
lim = "ERROR: You have hit your usage limit.\n"
rows = [ev(1, "fake", 1, 0.5, 1, lim), ev(2, "spy", 0, 5, 30, "VERDICT: APPROVED\n"), ev(3, "spy", 0, 10, 15, "VERDICT: BLOCKED\nCRITICAL: bad\n")]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
expect fail "an older approval that finished later does not override a newer blocked review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
# a failed spy call (missing input) is logged and, being the latest review, defeats an earlier approval.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation 'VERDICT: APPROVED\n'; cd "$tmp/run/repo"
bash "$here/spy-reviewer.sh" S "$tmp/no-such-input" >/dev/null 2>&1
expect pass "the failed spy call with a missing input is logged" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2]); print(len(e)==3 and e[-1]["exit"]!=0)' "$here" "$EVLOG")" = "True"
expect fail "a later failed review means the last review is not clean" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
# an unchanged CRLF plan hashes by raw bytes and matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan line\r\nsecond\r\n' > "$tmp/plan.md"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect pass "an unchanged CRLF plan matches the reviewed digest" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
# the event describes the snapshot, so a plan edited DURING the review no longer matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan v1\n' > "$tmp/plan.md"
EDIT_DURING="$tmp/plan.md" PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a plan edited while it was being reviewed is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
# the clean review is bound to the exact final .py state (paths, bytes, indentation, other modules, deletions).
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"
printf 'x=1\ndef add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a - b\n' > other.py
gdiff app.py other.py > "$tmp/diff.txt"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
cp "$tmp/run/repo/app.py" "$tmp/app.good"
expect pass "reviewed final code state is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
printf 'def evil():\n    pass\n' >> app.py
expect fail "code edited after the approval is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
cp "$tmp/app.good" app.py; printf 'def sub(a, b):\n    return a - b - 1\n' > other.py
expect fail "an edit to ANOTHER module after the approval is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
printf 'def sub(a, b):\n    return a - b\n' > other.py; sed -i.bak 's/^    return/        return/' app.py; rm -f app.py.bak
expect fail "an indentation-only change after the approval is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
cp "$tmp/app.good" app.py; rm other.py
expect fail "a deleted module after the approval is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
# last-verdict.py picks the latest execution by START time.
mkrun; python3 - "$EVLOG" <<'PY'
import json, sys
ev = lambda seq, st, ts, out: {"seq": seq, "wrapper": "fake", "argv": [], "exit": 0, "resume": None, "thread_id": None, "phase": "unknown", "stdout": out, "stderr": "", "ts_start": st, "ts": ts}
rows = [ev(1, 10, 15, "THREAD_ID: b\nVERDICT: BLOCKED\n"), ev(2, 5, 30, "THREAD_ID: a\nVERDICT: APPROVED\n")]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
expect pass "last-verdict picks the newer BLOCKED review, not the slower older APPROVED" test "$(python3 "$here/last-verdict.py" "$EVLOG")" = "BLOCKED"
# the codex shim mirrors codex-call.sh: turn.failed is a failure with diagnostics, and a thread id is never invented from the resume arg.
cat > "$tmp/bin/stubcodex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"T-real"}'
if [[ "${STUB_MODE:-}" == quota ]]; then echo '{"type":"turn.failed","error":{"message":"You have hit your usage limit."}}'; exit 1; fi
echo '{"type":"turn.completed"}'; exit 0
SH
chmod +x "$tmp/bin/stubcodex"
mkrun; cd "$tmp/run/repo"
STUB_MODE=quota REAL_CODEX="$tmp/bin/stubcodex" bash "$here/shim/codex" exec --json "prompt" >/dev/null 2>&1
expect pass "the shim logs a turn.failed quota error as a failed call with the diagnostics" python3 "$here/check-limit-hit.py" "$EVLOG"
expect pass "the failed call is normalized to exit 1 and carries the wrapper's terminal message" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[0]; print(e["exit"]==1 and "Treat as UNREVIEWED" in e["stderr"])' "$here" "$EVLOG")" = "True"
mkrun; cd "$tmp/run/repo"
REAL_CODEX="$tmp/bin/stubcodex" bash "$here/shim/codex" exec --json resume T-asked "prompt" >/dev/null 2>&1
expect pass "a completed turn with no agent message is logged as failed, with no invented thread id" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2]); print(e[0]["exit"]!=0 and e[0]["thread_id"] is None)' "$here" "$EVLOG")" = "True"


# the call log stays beside the event log even when the caller points FAKE_LOG elsewhere.
mkrun; cd "$tmp/run/repo"; FAKE_LOG="$tmp/elsewhere.log" bash "$fake" "review" >/dev/null 2>&1
expect pass "a caller-set FAKE_LOG cannot divert the call log" test "$(wc -l < "$tmp/run/calls.log" | tr -d ' ')" = "1"


# a partial diff (the add function only) does not cover the whole current implementation, even though the code state matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"
printf 'def add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a - b\n' > other.py
gdiff app.py > "$tmp/diff.txt"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a partial diff that omits another current module is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
# a failed spy run logs the stdout it replays to the caller too.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
printf '#!/usr/bin/env bash\necho "partial reply on stdout"\nexit 3\n' > "$tmp/bin2claude"; mkdir -p "$tmp/bin2"; cp "$tmp/bin2claude" "$tmp/bin2/claude"; chmod +x "$tmp/bin2/claude"
PATH="$tmp/bin2:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a failed reviewer's stdout is kept in the logged diagnostics" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[-1]; print(e["exit"]!=0 and "partial reply on stdout" in e["stderr"])' "$here" "$EVLOG")" = "True"

# r17: the reviewed diff must match the remaining change exactly (whitespace, operators, the file set).
rv() { mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; }
rv; printf 'def add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a + b\n' > other.py
gdiff app.py other.py > "$tmp/diff.txt"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect pass "an exact git diff of every changed module is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a + b\n' > other.py
gdiff app.py > "$tmp/diff.txt"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a diff omitting a module whose lines duplicate reviewed ones is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n        return a + b\n' > app.py
gdiff app.py | sed 's/^+        return/+    return/' > "$tmp/diff.txt"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a diff line with different indentation than the final code is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n    return a + b\n-x\n' > app.py
gdiff app.py | sed 's/^+-x$/+x/' > "$tmp/diff.txt"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a source operator dropped from a diff line is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n    return a + b\n-x\n' > app.py
gdiff app.py > "$tmp/diff.txt"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a line that starts with an operator is accepted when it is diffed exactly" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
# a spy whose output file cannot be written logs the shell diagnostic, not reviewer text the caller never saw.
rv; printf 'plan\n' > "$tmp/plan.md"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/nodir/out.txt" >/dev/null 2>"$tmp/spyerr.txt"
expect pass "an unwritable output file logs the shell diagnostic" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[-1]; print(e["exit"]!=0 and "nodir" in e["stderr"] and "VERDICT" not in e["stderr"])' "$here" "$EVLOG")" = "True"

# r17: the scripted scenarios are judged from the wrapper log, not calls.log.
sc() { python3 "$here/check-scripted.py" "$EVLOG" "$@"; }
mkrun; cd "$tmp/run/repo"; export FAKE_ROUNDS=1 FAKE_TARGET=code
bash "$fake" review >/dev/null 2>&1; printf '# review-fix-1\n' >> app.py; bash "$fake" review >/dev/null 2>&1
st="$({ cat app.py; } | shasum -a 256 | cut -c1-16)"
expect pass "scripted: a finding round then a clean reply for the final state passes" sh -c "python3 '$here/check-scripted.py' '$EVLOG' rounds 1 && python3 '$here/check-scripted.py' '$EVLOG' final $st"
expect fail "scripted: a clean reply for another state fails" python3 "$here/check-scripted.py" "$EVLOG" final 0000000000000000
bash "$fake" --resume never-issued again >/dev/null 2>&1
expect fail "scripted: a failed resume after the clean call means the last execution is not clean" python3 "$here/check-scripted.py" "$EVLOG" final "$st"
mkrun; cd "$tmp/run/repo"; export FAKE_ROUNDS=2; bash "$fake" review >/dev/null 2>&1
expect fail "scripted: a finding round never followed by round 2 fails the rounds check" python3 "$here/check-scripted.py" "$EVLOG" rounds 2
mkrun; cd "$tmp/run/repo"; export FAKE_ROUNDS=0 FAKE_FAIL_FIRST=2; for i in 1 2 3; do bash "$fake" review >/dev/null 2>&1; done
expect pass "scripted: two dead calls then a verdict satisfies failfirst 2" python3 "$here/check-scripted.py" "$EVLOG" failfirst 2
bash "$fake" --resume nope again >/dev/null 2>&1
expect fail "scripted: a bad call after the first verdict fails failfirst" python3 "$here/check-scripted.py" "$EVLOG" failfirst 2


# r18: nested modules, start-time order, spy success stderr, shim header.
rv; mkdir -p pkg; printf 'def add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a - b\n' > pkg/mod.py
gdiff app.py > "$tmp/diff.txt"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a diff omitting a nested module is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
gdiff app.py pkg/mod.py > "$tmp/diff.txt"; : > "$EVLOG"; line fake 1 unknown "$LIMIT"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a complete diff including a nested module is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
mkrun; python3 - "$EVLOG" <<'PY'
import json, sys
ev = lambda seq, st, ts, out, meta: {"seq": seq, "wrapper": "fake", "argv": [], "exit": 0, "resume": None, "thread_id": "t", "phase": "unknown", "stdout": out, "stderr": "", "ts_start": st, "ts": ts, "meta": meta}
clean = "THREAD_ID: t\nVERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n"
rows = [ev(1, 20, 21, "THREAD_ID: t\nVERDICT: WARNING\n", {"result": "HIGH", "round": "1", "state": "s", "impl": "yes"}), ev(2, 5, 30, clean, {"result": "CLEAN", "state": "s", "impl": "yes"})]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
expect fail "an older clean call that finished later is not the last execution" python3 "$here/check-scripted.py" "$EVLOG" final s
mkrun; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"; printf '#!/usr/bin/env bash\necho "noise" >&2\necho "VERDICT: APPROVED"\n' > "$tmp/bin2/claude"
PATH="$tmp/bin2:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a successful spy call logs no stderr it never replayed" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[-1]; print(e["exit"]==0 and e["stderr"]=="")' "$here" "$EVLOG")" = "True"
mkrun; cd "$tmp/run/repo"; printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/stubfail"; chmod +x "$tmp/bin/stubfail"
REAL_CODEX="$tmp/bin/stubfail" bash "$here/shim/codex" exec --json "prompt" >/dev/null 2>&1
expect pass "a silent Codex failure logs only the terminal message, no invented header" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[0]; print("Codex CLI said" not in e["stderr"] and "Treat as UNREVIEWED" in e["stderr"])' "$here" "$EVLOG")" = "True"

# r19: a quota error printed only on stderr is parsed from the merged stream like the wrapper does, once.
printf '#!/usr/bin/env bash\necho "ERROR: You have hit your usage limit." >&2\nexit 1\n' > "$tmp/bin/stderrquota"; chmod +x "$tmp/bin/stderrquota"
mkrun; cd "$tmp/run/repo"; REAL_CODEX="$tmp/bin/stderrquota" bash "$here/shim/codex" exec --json "prompt" >/dev/null 2>&1
expect pass "a stderr-only quota error is logged once through the wrapper's Codex CLI said header" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[0]; print(e["stderr"].count("usage limit")==1 and "Codex CLI said" in e["stderr"])' "$here" "$EVLOG")" = "True"
expect pass "and it counts as the usage limit" python3 "$here/check-limit-hit.py" "$EVLOG"
# the final status, not history: an early incomplete audit followed by an approved fallback is not flagged.

# r20: whatever the output path is, the reply reaches the caller exactly once and the event records exactly what was delivered.
for op in /dev/stdout /dev/fd/1 "$tmp/o.txt"; do
  mkrun; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
  got="$(PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$op" 2>/dev/null)"
  expect pass "spy delivers the reply once on stdout for output path $op" test "$(printf '%s\n' "$got" | grep -c '^VERDICT')" = 1
  expect pass "the event stdout equals what the caller received for $op" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[-1]; print(e["stdout"].strip()==sys.argv[3].strip())' "$here" "$EVLOG" "$got")" = "True"
done
mkrun; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" /dev/stderr >/dev/null 2>"$tmp/e.txt"
expect pass "a reply sent to /dev/stderr is logged as stderr, once" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[-1]; print(e["stderr"].count("VERDICT")==1 and e["stderr"].strip()==open(sys.argv[3]).read().strip())' "$here" "$EVLOG" "$tmp/e.txt")" = "True"

# r20: the reviewed patch must reproduce the final files from the baseline (hunk locations and context included).
commitbase() { (cd "$tmp/run/repo" && git add -A >/dev/null 2>&1 && git update-ref HEAD "$(echo base | git commit-tree "$(git write-tree)")"); }
mkrun; cd "$tmp/run/repo"; printf 'k\nk\nk\ndef add(a, b):\n    return a + b\n' > app.py; commitbase
printf 'k\nNEW\nk\nk\ndef add(a, b):\n    return a + b\n' > app.py
git diff --no-color HEAD -- app.py > "$tmp/good.diff"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/good.diff" "$tmp/out.txt" >/dev/null 2>&1; : > "$tmp/x"
line fake 1 unknown "$LIMIT" ; python3 - "$EVLOG" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; spy=[r for r in rows if r["wrapper"]=="spy"]; fake=[r for r in rows if r["wrapper"]!="spy"]
fake[0]["ts"]=spy[0]["ts_start"]-5; fake[0]["ts_start"]=fake[0]["ts"]-1
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in fake+spy)+"\n")
PY
expect pass "a reviewed patch that reproduces the final file is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
# same added line, wrong location: the patch inserts NEW after the second k
sed -e 's/^@@.*/@@ -1,4 +1,5 @@/' "$tmp/good.diff" > /dev/null
mkrun; cd "$tmp/run/repo"; printf 'k\nk\nk\ndef add(a, b):\n    return a + b\n' > app.py; commitbase
printf 'k\nNEW\nk\nk\ndef add(a, b):\n    return a + b\n' > app.py
cat > "$tmp/stale.diff" <<'D'
diff --git a/app.py b/app.py
--- a/app.py
+++ b/app.py
@@ -1,5 +1,6 @@
 k
 k
+NEW
 k
 def add(a, b):
     return a + b
D
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/stale.diff" "$tmp/out.txt" >/dev/null 2>&1
line fake 1 unknown "$LIMIT"; python3 - "$EVLOG" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; spy=[r for r in rows if r["wrapper"]=="spy"]; fake=[r for r in rows if r["wrapper"]!="spy"]
fake[0]["ts"]=spy[0]["ts_start"]-5; fake[0]["ts_start"]=fake[0]["ts"]-1
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in fake+spy)+"\n")
PY
expect fail "a stale patch with the same added line at another location is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"

# r20: the proof asserts on one structured AUDIT-STATUS line only
st() { printf '%s\n' "$1" > "$tmp/rep.txt"; shift; python3 "$here/audit-status.py" "$tmp/rep.txt" "$@"; }
expect pass "a report ending in an APPROVED status line is accepted" st $'Initial review: UNREVIEWED. Retry ok.\nAUDIT-STATUS: APPROVED reviewer=codex' --expect APPROVED
expect fail "prose saying UNREVIEWED with no status line is rejected" st "The changes remain UNREVIEWED."
expect fail "an UNREVIEWED status is rejected when APPROVED is expected" st $'x\nAUDIT-STATUS: UNREVIEWED reviewer=none' --expect APPROVED
expect pass "an UNREVIEWED status matches an UNREVIEWED expectation" st $'x\nAUDIT-STATUS: UNREVIEWED reviewer=none' --expect UNREVIEWED
expect fail "two status lines are rejected" st $'AUDIT-STATUS: UNREVIEWED reviewer=none\nAUDIT-STATUS: APPROVED reviewer=codex'
expect fail "a status line that is not last is rejected" st $'AUDIT-STATUS: APPROVED reviewer=codex\nThanks'
expect fail "a malformed status line is rejected" st $'AUDIT-STATUS: DONE reviewer=codex'
expect pass "a trailing blank line after the status is fine" st $'AUDIT-STATUS: APPROVED reviewer=sonnet\n\n' --expect APPROVED
expect pass "every skill and command carries identical mirrored instructions" python3 "$here/test-mirrors.py"

# r21: reviewed-patch hardening, CRLF, single stderr delivery, mirror clause equality, codex-mcp scoping
limit_then_spy() { # diff-file : runs the spy on it from the repo, then orders a quota event before it
  PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$1" "$tmp/out.txt" >/dev/null 2>&1
  line fake 1 unknown "$LIMIT"; python3 - "$EVLOG" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; spy=[r for r in rows if r["wrapper"]=="spy"]; fake=[r for r in rows if r["wrapper"]!="spy"]
fake[0]["ts"]=spy[0]["ts_start"]-5; fake[0]["ts_start"]=fake[0]["ts"]-1
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in fake+spy)+"\n")
PY
}
mkrun; cd "$tmp/run/repo"; printf 'k\ndef add(a, b):\n    return a + b\n' > app.py; commitbase
printf 'k\nNEW\ndef add(a, b):\n    return a + b\n' > app.py
git diff --no-color HEAD -- app.py > "$tmp/trav.diff"
printf 'diff --git a/app.py b/../escape.py\ncopy from app.py\ncopy to ../escape.py\n' >> "$tmp/trav.diff"
limit_then_spy "$tmp/trav.diff"
expect fail "a copy-only section that writes outside the sandbox is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
test ! -e "$tmp/run/escape.py"; expect pass "the escaping copy target was never created" test ! -e "$tmp/run/escape.py"
mkrun; cd "$tmp/run/repo"; printf 'k\r\ndef add(a, b):\r\n    return a + b\r\n' > app.py; commitbase
printf 'k\r\nNEW\r\ndef add(a, b):\r\n    return a + b\r\n' > app.py
git diff --no-color HEAD -- app.py > "$tmp/crlf.diff"
limit_then_spy "$tmp/crlf.diff"
expect pass "a correctly reviewed CRLF file is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
mkrun; PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" /dev/stderr >"$tmp/so.txt" 2>"$tmp/se.txt"
expect pass "a reply sent to /dev/stderr reaches the caller exactly once across both streams" test "$(cat "$tmp/so.txt" "$tmp/se.txt" | grep -c '^VERDICT')" = 1
rm -rf "$tmp/mir"; mkdir -p "$tmp/mir"; cp -R "$here/../skills" "$here/../commands" "$tmp/mir/"
python3 - "$tmp/mir/commands/claude-codex.md" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
assert "no Codex thread is required" in s or "tier S included" in s
assert "it must record its evidence" in s
s=s.replace("it must record its evidence","it need not record its evidence",1)
open(p,"w").write(s)
PY
expect fail "a reversed clause in one command copy is caught by the mirror test" python3 "$here/test-mirrors.py" "$tmp/mir"
expect pass "every audit-status assertion in the proof is skipped for the codex-mcp guide" test "$(grep -c 'audit-status.py' "$here/review-loop-proof.sh")" = "$(grep 'audit-status.py' "$here/review-loop-proof.sh" | grep -c 'codex-mcp')"

# r22: formatting-independent phase, resume reply that repeats its thread id, whole quota paragraphs mirrored
mkrun; cd "$tmp/run/repo"; printf 'def add (a, b): return (a + b)\n' > "$tmp/fmt.py"; git diff --no-index --no-color /dev/null "$tmp/fmt.py" > "$tmp/fmt.diff"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/fmt.diff" "$tmp/out.txt" >/dev/null 2>&1
expect pass "an implementation formatted as def add (a, b): return (a + b) is phase implementation" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["phase"])' "$here" "$EVLOG")" = implementation
grep -q "has_add=yes" "$tmp/run/spy.log"; expect pass "the spy marks the oddly formatted add as implemented" grep -q "impl=yes" "$tmp/run/spy.log"
mkrun
python3 - "$EVLOG" <<'PY'
import json, sys
rows = [{"seq": 1, "wrapper": "fake", "argv": [], "exit": 0, "resume": "", "thread_id": "t-1", "phase": "unknown", "stdout": "THREAD_ID: t-1\nstarted\n", "stderr": "", "ts": 1},
        {"seq": 2, "wrapper": "fake", "argv": [], "exit": 0, "resume": "t-1", "thread_id": "t-1", "phase": "unknown", "stdout": "THREAD_ID: t-1\nDone, continuing thread:\nTHREAD_ID: t-1\n", "stderr": "", "ts": 2}]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
expect pass "--no-verdict accepts a correct resume whose message repeats the thread id" python3 "$here/check-resume.py" "$EVLOG" --no-verdict
rm -rf "$tmp/mir"; mkdir -p "$tmp/mir"; cp -R "$here/../skills" "$here/../commands" "$tmp/mir/"
python3 - "$tmp/mir/commands/execute-codex.md" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a="never counts as the review then"
assert a in s
open(p,"w").write(s.replace(a, "counts as the review then", 1))
PY
expect fail "a contradicting quota paragraph in one command copy is caught by the mirror test" python3 "$here/test-mirrors.py" "$tmp/mir"

# r23: unchanged empty baseline file, reply routed to stderr, closing code fence after the status
mkrun; cd "$tmp/run/repo"; : > __init__.py; printf 'k\ndef add(a, b):\n    return a + b\n' > app.py; commitbase
printf 'k\nNEW\ndef add(a, b):\n    return a + b\n' > app.py
git diff --no-color HEAD -- app.py > "$tmp/empty.diff"
limit_then_spy "$tmp/empty.diff"
expect pass "a valid review beside an unchanged empty baseline file is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
mkrun; cd "$tmp/run/repo"; printf 'k\ndef add(a, b):\n    return a + b\n' > app.py; commitbase
printf 'k\nNEW\ndef add(a, b):\n    return a + b\n' > app.py
git diff --no-color HEAD -- app.py > "$tmp/err.diff"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/err.diff" /dev/stderr >/dev/null 2>&1
line fake 1 unknown "$LIMIT"; python3 - "$EVLOG" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; spy=[r for r in rows if r["wrapper"]=="spy"]; fake=[r for r in rows if r["wrapper"]!="spy"]
fake[0]["ts"]=spy[0]["ts_start"]-5; fake[0]["ts_start"]=fake[0]["ts"]-1
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in fake+spy)+"\n")
PY
expect pass "a clean spy review delivered through /dev/stderr counts as clean" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
expect fail "a report whose last non-blank line is a closing fence after the status is rejected" st $'```\nAUDIT-STATUS: APPROVED reviewer=codex\n```'

# r24: structural phase, no-stop clause mirrored, shim subcommand parsing, git add -N never adds every untracked file
mkrun; cd "$tmp/run/repo"
printf 'add = lambda a, b: a + b\n' > "$tmp/lam.py"; git diff --no-index --no-color /dev/null "$tmp/lam.py" > "$tmp/lam.diff"
PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/lam.diff" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a lambda implementation is phase implementation" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["phase"])' "$here" "$EVLOG")" = implementation
mkdir -p "$tmp/tt"; printf 'def test_x():\n    def helper(a, b):\n        return a + b\n    assert helper(1, 2) == 3\n' > "$tmp/tt/test_app.py"; git diff --no-index --no-color /dev/null "$tmp/tt/test_app.py" > "$tmp/tt.diff"
mkrun; cd "$tmp/run/repo"; PATH="$tmp/bin:$PATH" SPY_LOG="$tmp/run/spy.log" bash "$here/spy-reviewer.sh" S "$tmp/tt.diff" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a tests-only diff containing return a + b is phase tests" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["phase"])' "$here" "$EVLOG")" = tests
cat > "$tmp/bin/stubok" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"T-real"}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"VERDICT: APPROVED"}}'
echo '{"type":"turn.completed"}'; exit 0
SH
chmod +x "$tmp/bin/stubok"
mkrun; cd "$tmp/run/repo"
REAL_CODEX="$tmp/bin/stubok" bash "$here/shim/codex" exec -p review --sandbox read-only --cd "$tmp/run/repo" --json --skip-git-repo-check "resume" >/dev/null 2>&1
expect pass "a new call whose prompt is the word resume is not logged as a resume" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["resume"])' "$here" "$EVLOG")" = "None"
REAL_CODEX="$tmp/bin/stubok" bash "$here/shim/codex" exec -p review --sandbox read-only --cd "$tmp/run/repo" resume --json --skip-git-repo-check T-real "again" >/dev/null 2>&1
expect pass "a real resume is logged with its thread id" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["resume"])' "$here" "$EVLOG")" = "T-real"
rm -rf "$tmp/mir"; mkdir -p "$tmp/mir"; cp -R "$here/../skills" "$here/../commands" "$tmp/mir/"
python3 - "$tmp/mir/commands/tdd-execute-codex.md" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a="Never conclude the reviewer is stuck"; assert a in s
open(p,"w").write(s.replace(a,"Always conclude the reviewer is stuck",1))
PY
expect fail "a reversed no-stop clause in one command copy is caught by the mirror test" python3 "$here/test-mirrors.py" "$tmp/mir"
rm -rf "$tmp/mir"; mkdir -p "$tmp/mir"; cp -R "$here/../skills" "$here/../commands" "$tmp/mir/"
sed -i '' 's/`git add -N <each file this task created>`/`git add -N .`/' "$tmp/mir/skills/claude-codex/SKILL.md"
expect fail "a git add -N . instruction in a skill is rejected" python3 "$here/test-mirrors.py" "$tmp/mir"

# r25b: no-stop exit rule compared in full, zero-context reviewed patches, real-basic ignores non-real wrappers
rm -rf "$tmp/mir"; mkdir -p "$tmp/mir"; cp -R "$here/../skills" "$here/../commands" "$tmp/mir/"
python3 - "$tmp/mir/commands/tdd-execute-codex.md" <<'PY2'
import sys; p=sys.argv[1]; s=open(p).read()
a="and the only other exit is the failed-review rule."; assert a in s
open(p,"w").write(s.replace(a,"and you may stop after three rounds.",1))
PY2
expect fail "a command that permits stopping after three rounds is caught by the mirror test" python3 "$here/test-mirrors.py" "$tmp/mir"
mkrun; cd "$tmp/run/repo"; printf 'k\ndef add(a, b):\n    return a + b\n' > app.py; commitbase
printf 'k\nNEW\ndef add(a, b):\n    return a + b\n' > app.py
git diff -U0 --no-color HEAD -- app.py > "$tmp/u0.diff"
limit_then_spy "$tmp/u0.diff"
expect pass "a correctly reviewed zero-context patch is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
mkrun; line spy 0 implementation 'THREAD_ID: abcdef12-3456\nVERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n'
expect fail "a spy reply does not satisfy the real thread check" python3 "$here/check-real-basic.py" "$EVLOG" thread
expect fail "a spy reply does not satisfy the real verdict check" python3 "$here/check-real-basic.py" "$EVLOG" verdict
mkrun; line real 0 implementation 'THREAD_ID: abcdef12-3456\nVERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n'
expect pass "a real wrapper reply satisfies the real thread check" python3 "$here/check-real-basic.py" "$EVLOG" thread
expect pass "a real wrapper reply satisfies the real verdict check" python3 "$here/check-real-basic.py" "$EVLOG" verdict

exit $fail
