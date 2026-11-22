#!/usr/bin/env bash
# test-checkers.sh: each r11 review finding as a case that must hold. Every case drives the REAL stand-in
# wrapper (or a hand-built log line) and then asks a checker, which reads only the wrapper event log.
# Run: bash tests/test-checkers.sh   (no Claude, no network)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
# WHY a hard prerequisite (CodeRabbit r47): the launcher cases run the REAL installed reviewer.sh (~/.claude/config/scripts/reviewer.sh, or
# SPY_CONFIG_DIR); without it they would fail in confusing ways, so stop with one clear line.
[[ -n "${CHECKERS_NO_SPY:-}" || -f "${SPY_CONFIG_DIR:-$HOME/.claude/config}/scripts/reviewer.sh" ]] || { echo "FAIL: installed reviewer.sh not found under ${SPY_CONFIG_DIR:-$HOME/.claude/config}/scripts (required by this suite)"; exit 1; }
# WHY a portable timeout (cc11-main-r1): GNU `timeout` is not on stock macOS (coreutils installs it as `gtimeout`), so use whichever exists and
# otherwise a python3 stand-in with the same contract (kill on expiry, exit 124). TMO_FORCE_PY=1 forces the stand-in so it can be tested.
tmo() {
  local secs="$1"; shift
  if [[ -z "${TMO_FORCE_PY:-}" ]] && command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif [[ -z "${TMO_FORCE_PY:-}" ]] && command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else
    # WHY a new session and killpg (cc11-main-r2 finding 6): p.kill() only reaches the immediate child, so a timed-out launcher left its
    # reviewer and tee descendants running. start_new_session makes the child a group leader; killpg takes the whole group down on expiry.
    python3 -c 'import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    sys.exit(p.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); p.wait(); sys.exit(124)' "$secs" "$@"
  fi
}
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
# WHY CHECKERS_NO_SPY (public CI): the spy-reviewer cases run the PRIVATE installed reviewer.sh, which a clean clone and CI do not have. With
# CHECKERS_NO_SPY=1 spy-reviewer.sh and copy-config.sh only drop $spymark and exit 0; every `expect` that follows a spy call in the same run
# directory is skipped and counted (mkrun clears the mark). Nothing else is skipped, and the count is printed at the end so a silent skip is visible.
skipped=0; spymark="$tmp/spy-used"; export CHECKERS_SPY_MARK="$spymark"
expect() { local want="$1" name="$2"; shift 2; if [[ -n "${CHECKERS_NO_SPY:-}" && -e "$spymark" ]]; then skipped=$((skipped+1)); echo "SKIP: $name"; return 0; fi; "$@" >/dev/null 2>&1; local rc=$?; if { [[ $want == pass && $rc -eq 0 ]] || [[ $want == fail && $rc -ne 0 ]]; }; then ok "$name"; else bad "$name (rc=$rc, wanted $want)"; fi; }
# cc11-main-r2 finding 6: the python3 timeout stand-in must kill the whole process group, not only its child, or a timed-out launcher leaves reviewer and tee processes running.
mkdir -p "$tmp/tmo"; rm -f "$tmp/tmo/gpid"
TMO_FORCE_PY=1 tmo 1 bash -c 'sleep 60 & echo $! > "$1"; wait' _ "$tmp/tmo/gpid" >/dev/null 2>&1; tmo_rc=$?
sleep 1
expect pass "the python3 timeout stand-in exits 124 on expiry" test "$tmo_rc" -eq 124
expect fail "the python3 timeout stand-in leaves no grandchild running after expiry" kill -0 "$(cat "$tmp/tmo/gpid" 2>/dev/null || echo 99999999)"
kill "$(cat "$tmp/tmo/gpid" 2>/dev/null)" >/dev/null 2>&1 || true  # tidy up when the case above failed
gdiff() { local f; for f in "$@"; do git diff --no-index --no-color /dev/null "$f"; done; }
mkrun() { rm -f "$spymark"; cd "$tmp"; rm -rf "$tmp/run"; mkdir -p "$tmp/run/repo"; (cd "$tmp/run/repo" && git init -q && git remote add origin https://example.invalid/t/r.git && printf 'x=1\n' > app.py); cd "$tmp/run/repo"; export EVLOG="$tmp/run/wrapper.jsonl" FAKE_LOG="$tmp/run/calls.log"; : > "$EVLOG"; : > "$FAKE_LOG"; unset FAKE_LIMIT FAKE_FAIL_FIRST; export FAKE_ROUNDS=0; }
fake="$here/fake-codex-call.sh"
# viawrap runs the shim from a script named codex-call.sh, the way the installed wrapper does (shim provenance, r28)
mkdir -p "$tmp/wrap"; printf '#!/usr/bin/env bash\nbash "%s/shim/codex" "$@"\nrc=$?\nexit $rc\n' "$here" > "$tmp/wrap/codex-call.sh"
viawrap() { bash "$tmp/wrap/codex-call.sh" "$@"; }
# provenance expectations (r29): nonce, hash of the reviewed wrapper and the real codex path, as the harness exports them
export EVNONCE=testnonce WRAPPER_SHA256="$(shasum -a 256 "$tmp/wrap/codex-call.sh" | cut -d' ' -f1)"
mkdir -p "$tmp/realbin"; export EXPECT_CODEX="$tmp/realbin/codex"
line() { # wrapper exit phase stdout   -> appends a hand-built event
  python3 - "$EVLOG" "$@" <<'PY'
import json, sys
log, wrapper, code, phase, out = sys.argv[1:6]
n = sum(1 for _ in open(log))
import os
prov = {"argv_ok": True, "nonce": os.environ["EVNONCE"], "wrapper_sha256": os.environ["WRAPPER_SHA256"], "codex": os.path.realpath(os.environ["EXPECT_CODEX"])} if wrapper == "real" else None
ev = {"seq": n + 1, "wrapper": wrapper, "prov": prov, "argv": ["S", "in", "out"] if wrapper == "spy" else [], "exit": int(code), "resume": None, "thread_id": None, "phase": phase, "stdout": out.replace("\\n", "\n"), "stderr": "", "ts": n + 1}
if wrapper == "spy":
    # a hand-built launcher event comes with the fake model production called for it (same run id), as the real launcher does (r38)
    ev["meta"] = {"run": "r%d" % (n + 1)}; ev["input_text"] = "in"
with open(log, "a") as f:
    f.write(json.dumps(ev) + "\n")
    if wrapper == "spy":
        f.write(json.dumps({"seq": n + 2, "wrapper": "model", "prov": None, "argv": ["claude", "-p", "<prompt>"], "exit": 0, "resume": None, "thread_id": None, "phase": phase, "stdout": "VERDICT: APPROVED\n", "stderr": "", "meta": {"bin": "claude", "tier": "S", "run": "r%d" % (n + 1)}, "input_text": "prompt in", "ts": n + 1}) + "\n")
PY
}
CLEAN='VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n'
CLEANR='VERDICT: APPROVED\n'
LIMIT='codex-call: Codex turn did not complete\nERROR: You have hit your usage limit.\n'

# (r11 a) a tests-only review after the quota hit is not the implementation review.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 tests "$CLEANR"
expect fail "tests-only reviewer after the quota hit is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
line spy 0 implementation "$CLEANR"
expect pass "a later clean implementation review is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
mkrun; line spy 0 implementation "$CLEANR"; line fake 1 unknown "$LIMIT"
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
# WHY the fixture is built with `line` (a valid launcher event plus its fake model event) and only then retimed: every other check in
# the checker passes, so ONLY the start-time rule decides these cases. The earlier hand-built rows failed on missing model events first,
# so removing the start-time rule left the test green (CodeRabbit/Codex cc11-main-r1).
retime() { python3 - "$EVLOG" "$@" <<'PYT'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
for spec in sys.argv[2:]:
    i, st, ts = spec.split(":")
    rows[int(i)]["ts_start"] = float(st); rows[int(i)]["ts"] = float(ts)
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PYT
}
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation 'VERDICT: APPROVED\n'; retime 0:9:10 1:11:20
expect pass "control: a review that started after the quota reply and finished later is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation 'VERDICT: APPROVED\n'; retime 0:9:10 1:5:20
expect fail "a review that started before the quota reply but finished after is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
# THREAD_ID text inside a spy reply is extra text, not a transport line.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation "THREAD_ID: abc\n$CLEAN"
expect fail "a THREAD_ID line inside a reviewer reply breaks clean" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
# plan-codex: the clean review must be of the current non-empty plan file.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 plan "$CLEANR"
: > "$tmp/plan.md"
expect fail "an empty plan file never satisfies the plan review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
printf 'the plan\n' > "$tmp/plan.md"
expect fail "a plan that differs from the reviewed input is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
# a real spy run on the plan file logs its sha, which then matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"
printf 'the plan\n' > "$tmp/plan.md"; bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
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
# WHY a valid approval plus a valid-shaped blocked review: only the ordering (start time vs finish time) decides the verdict here.
addblocked() { python3 - "$EVLOG" <<'PYB'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
rows.append({"seq": 9, "wrapper": "spy", "prov": None, "argv": ["S", "in", "out"], "exit": 0, "resume": None, "thread_id": None, "phase": "implementation", "stdout": "VERDICT: BLOCKED\nCRITICAL: bad\n", "stderr": "", "ts_start": 10, "ts": 15, "meta": {"run": "r9"}, "input_text": "in"})
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PYB
}
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation 'VERDICT: APPROVED\n'; retime 0:0.5:1 1:5:30
expect pass "control: the same approval with no newer review is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
addblocked
expect fail "an older approval that finished later does not override a newer blocked review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
# a failed spy call (missing input) is logged and, being the latest review, defeats an earlier approval.
mkrun; line fake 1 unknown "$LIMIT"; line spy 0 implementation 'VERDICT: APPROVED\n'; cd "$tmp/run/repo"
bash "$here/spy-reviewer.sh" S "$tmp/no-such-input" "$tmp/o.txt" >/dev/null 2>&1
expect pass "the failed spy call with a missing input is logged" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2]); print(len(e)==4 and e[-1]["exit"]!=0)' "$here" "$EVLOG")" = "True"
expect fail "a later failed review means the last review is not clean" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
# an unchanged CRLF plan hashes by raw bytes and matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan line\r\nsecond\r\n' > "$tmp/plan.md"
bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect pass "an unchanged CRLF plan matches the reviewed digest" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
# r37: a tier R review is of committed repository state, so it never validates a plan file
python3 - "$EVLOG" "$tmp/evR.jsonl" <<'PYR'
import json, sys
out = open(sys.argv[2], "w")
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["wrapper"] == "spy": e["argv"][0] = "R"
    out.write(json.dumps(e) + "\n")
PYR
expect fail "a tier R spy review does not validate the plan file" python3 "$here/check-reviewer-after-limit.py" "$tmp/evR.jsonl" --plan-file "$tmp/plan.md"
# the event describes the snapshot, so a plan edited DURING the review no longer matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan v1\n' > "$tmp/plan.md"
EDIT_DURING="$tmp/plan.md" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a plan edited while it was being reviewed is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
# the clean review is bound to the exact final .py state (paths, bytes, indentation, other modules, deletions).
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"
printf 'x=1\ndef add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a - b\n' > other.py
gdiff app.py other.py > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
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
SV = "CRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n"  # complete blocks: only the timing differs, so only the timing decides
rows = [ev(1, 10, 15, "THREAD_ID: b\nVERDICT: BLOCKED\n" + SV), ev(2, 5, 30, "THREAD_ID: a\nVERDICT: APPROVED\n" + SV)]
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
STUB_MODE=quota REAL_CODEX="$tmp/bin/stubcodex" EXPECT_CODEX="$tmp/bin/stubcodex" viawrap exec --json "prompt" >/dev/null 2>&1
expect pass "the shim logs a turn.failed quota error as a failed call with the diagnostics" env EXPECT_CODEX="$tmp/bin/stubcodex" python3 "$here/check-limit-hit.py" "$EVLOG"
expect pass "the failed call is normalized to exit 1 and carries the wrapper's terminal message" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[0]; print(e["exit"]==1 and "Treat as UNREVIEWED" in e["stderr"])' "$here" "$EVLOG")" = "True"
mkrun; cd "$tmp/run/repo"
REAL_CODEX="$tmp/bin/stubcodex" viawrap exec --json resume T-asked "prompt" >/dev/null 2>&1
expect pass "a completed turn with no agent message is logged as failed, with no invented thread id" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2]); print(e[0]["exit"]!=0 and e[0]["thread_id"] is None)' "$here" "$EVLOG")" = "True"


# the call log stays beside the event log even when the caller points FAKE_LOG elsewhere.
mkrun; cd "$tmp/run/repo"; FAKE_LOG="$tmp/elsewhere.log" bash "$fake" "review" >/dev/null 2>&1
expect pass "a caller-set FAKE_LOG cannot divert the call log" test "$(wc -l < "$tmp/run/calls.log" | tr -d ' ')" = "1"


# a partial diff (the add function only) does not cover the whole current implementation, even though the code state matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"
printf 'def add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a - b\n' > other.py
gdiff app.py > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a partial diff that omits another current module is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
# a failing model binary: production rejects it, the launcher exits non-zero and the model event keeps what the binary printed.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
FAKE_CLAUDE_MODE=fail bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a failed model run fails the launcher and its output stays in the model event" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); m=[e for e in es if e["wrapper"]=="model"][-1]; print(es[-1]["wrapper"]=="spy" and es[-1]["exit"]!=0 and m["exit"]==3 and "partial reply on stdout" in m["stdout"])' "$here" "$EVLOG")" = "True"

# cc11-main-r2 finding 1: a model call that exits nonzero after printing VERDICT: APPROVED is no verdict. The skills can only see what the
# reviewer launcher returns (its exit status and output), never the private model logs, so the launcher itself must exit non-zero.
# WHY this fails against an installed reviewer.sh whose run_sonnet swallows the model exit status (SPY_CONFIG_DIR=$HOME/.claude/config) and
# passes once the fixed reviewer.sh from the Global Config consolidated PR is the one installed (SPY_CONFIG_DIR=<that worktree>).
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
FAKE_CLAUDE_MODE=failapproved bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1; rc_failapproved=$?
expect pass "a nonzero model call that printed VERDICT: APPROVED makes the reviewer launcher exit non-zero (no verdict)" test "$rc_failapproved" -ne 0
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect pass "control: the same call with a zero exit and the same approval is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"

# cc11-main-r2 finding 2: the guard that decides whether tier R (CodeRabbit, which reads the commits itself) may be used must really list committed secret-named files, even from a subdirectory.
for guard_file in skills/execute-codex/SKILL.md skills/claude-codex/SKILL.md skills/tdd-execute-codex/SKILL.md skills/tdd-claude-codex/SKILL.md; do
  expect pass "the tier R secret guard in $guard_file lists committed secret files from a subfolder" python3 "$here/check-secret-guard.py" "$here/../$guard_file"
done

# cc11-main-r2 finding 3: the diff command each workflow prescribes is relative to the repository top, not to the shell's folder.
for f in skills/claude-codex/SKILL.md commands/claude-codex.md skills/execute-codex/SKILL.md commands/execute-codex.md skills/tdd-claude-codex/SKILL.md commands/tdd-claude-codex.md skills/tdd-execute-codex/SKILL.md commands/tdd-execute-codex.md; do
  expect pass "the reviewer diff command in $f lists changes in sibling folders when run from a subfolder" python3 "$here/check-diff-toplevel.py" "$here/../$f"
done
# WHY a recording fake codex: it proves what --cd the wrapper really passes, instead of grepping the wrapper's source.
mkdir -p "$tmp/cdbin" "$tmp/cdrepo/sub"; (cd "$tmp/cdrepo" && git init -q)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/cdargs.txt"\nexit 1\n' "$tmp" > "$tmp/cdbin/codex"; chmod +x "$tmp/cdbin/codex"
(cd "$tmp/cdrepo/sub" && PATH="$tmp/cdbin:$PATH" bash "$here/../scripts/codex-call.sh" "p" >/dev/null 2>&1)
expect pass "codex-call.sh defaults --cd to the repository top when started from a subfolder" test "$(grep -A1 -x -e '--cd' "$tmp/cdargs.txt" | tail -1)" = "$(cd "$tmp/cdrepo" && pwd -P)"

# cc11-main-r2 finding 5: GNU sed rejects the BSD-only empty backup suffix form of in-place sed. The portable form is `sed -i.bak ... && rm -f <file>.bak`.
bsd_sed="sed -i ''"
expect pass "the suite uses no BSD-only in-place sed" test -z "$(grep -n -F -e "$bsd_sed" "$here/test-checkers.sh" | grep -v 'bsd_sed=')"

# C5: the public CI workflow keeps its safety properties (explicit read-only permissions, no persisted credentials, the spy switch, per-ref concurrency).
ci="$here/../.github/workflows/ci.yml"
expect pass "ci.yml declares an explicit contents: read permissions block" grep -qE '^permissions:$' "$ci"
expect pass "ci.yml checks out with persist-credentials: false" grep -q 'persist-credentials: false' "$ci"
expect pass "ci.yml runs the checkers with CHECKERS_NO_SPY=1" grep -q 'CHECKERS_NO_SPY=1 bash tests/test-checkers.sh' "$ci"
expect pass "ci.yml cancels superseded pull request runs per ref" grep -q 'cancel-in-progress: ${{ github.event_name == '"'"'pull_request'"'"' }}' "$ci"
expect pass "ci.yml runs on pull_request and pushes to main only" grep -qE '^  push:$' "$ci"

# C4: codex-call v2 error handling: a JSON error event with no message is reported whole instead of as an empty line, and the contract line is present.
mkdir -p "$tmp/errbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "{\\"type\\":\\"thread.started\\",\\"thread_id\\":\\"t1\\"}" "{\\"type\\":\\"error\\",\\"code\\":\\"usage_limit\\"}" "{\\"type\\":\\"turn.failed\\"}"\nexit 1\n' > "$tmp/errbin/codex"; chmod +x "$tmp/errbin/codex"
PATH="$tmp/errbin:$PATH" bash "$here/../scripts/codex-call.sh" "p" >/dev/null 2>"$tmp/errout.txt"
expect pass "codex-call.sh reports a message-less JSON error event whole (usage_limit visible)" grep -q "usage_limit" "$tmp/errout.txt"
expect pass "codex-call.sh carries the v2 contract line" grep -qx '# contract: codex-call v2 (source of truth: hellosurbhi/claude-codex scripts/codex-call.sh)' "$here/../scripts/codex-call.sh"

# CodeRabbit thread 7 (evlog.py:28): a marked plan that quotes a function signature is still a plan, not the implementation.
expect pass "a marked plan containing def add(a, b) is classified as a plan" test "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import evlog; print(evlog.phase_of("# Implementation plan\n\nAdd:\n    def add(a, b):\n        return a + b\n"))' "$here")" = "plan"
expect pass "a diff of an implementation file that contains def add is still the implementation" test "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import evlog; print(evlog.phase_of("diff --git a/app.py b/app.py\n+def add(a, b):\n"))' "$here")" = "implementation"
expect pass "unmarked text with def add(a, b) stays the implementation" test "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import evlog; print(evlog.phase_of("def add(a, b):\n    return a + b\n"))' "$here")" = "implementation"

# r17: the reviewed diff must match the remaining change exactly (whitespace, operators, the file set).
rv() { mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; }
rv; printf 'def add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a + b\n' > other.py
gdiff app.py other.py > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect pass "an exact git diff of every changed module is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a + b\n' > other.py
gdiff app.py > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a diff omitting a module whose lines duplicate reviewed ones is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n        return a + b\n' > app.py
gdiff app.py | sed 's/^+        return/+    return/' > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a diff line with different indentation than the final code is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n    return a + b\n-x\n' > app.py
gdiff app.py | sed 's/^+-x$/+x/' > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a source operator dropped from a diff line is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n    return a + b\n-x\n' > app.py
gdiff app.py > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a line that starts with an operator is accepted when it is diffed exactly" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
# a spy whose output file cannot be written logs the shell diagnostic, not reviewer text the caller never saw.
rv; printf 'plan\n' > "$tmp/plan.md"
bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/nodir/out.txt" >/dev/null 2>"$tmp/spyerr.txt"
expect pass "an unwritable output file logs production's outage message" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[-1]; print(e["exit"]!=0 and "UNAVAILABLE" in e["stderr"] and "VERDICT" not in e["stderr"])' "$here" "$EVLOG")" = "True"

# r17: the scripted scenarios are judged from the wrapper log, not calls.log.
sc() { python3 "$here/check-scripted.py" "$EVLOG" "$@"; }
mkrun; cd "$tmp/run/repo"; export FAKE_ROUNDS=1 FAKE_TARGET=code
bash "$fake" review >/dev/null 2>&1; printf '# review-fix-1\n' >> app.py; bash "$fake" review >/dev/null 2>&1
st="$(python3 "$here/state-hash.py" .)"
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
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect fail "a diff omitting a nested module is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
gdiff app.py pkg/mod.py > "$tmp/diff.txt"; : > "$EVLOG"; line fake 1 unknown "$LIMIT"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a complete diff including a nested module is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
mkrun; python3 - "$EVLOG" <<'PY'
import json, sys
ev = lambda seq, st, ts, out, meta: {"seq": seq, "wrapper": "fake", "argv": [], "exit": 0, "resume": None, "thread_id": "t", "phase": "unknown", "stdout": out, "stderr": "", "ts_start": st, "ts": ts, "meta": meta}
clean = "THREAD_ID: t\nVERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n"
rows = [ev(1, 20, 21, "THREAD_ID: t\nVERDICT: WARNING\n", {"result": "HIGH", "round": "1", "state": "s", "impl": "yes"}), ev(2, 5, 30, clean, {"result": "CLEAN", "state": "s", "impl": "yes"})]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
expect fail "an older clean call that finished later is not the last execution" python3 "$here/check-scripted.py" "$EVLOG" final s
mkrun; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
FAKE_CLAUDE_NOISE="noise from the model" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
# WHY the noise is generated by the fake model (r41): the launcher's PATH prefix shadows any stub placed in front of it.
expect pass "the model really wrote stderr noise" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(any("noise from the model" in e["stderr"] for e in wlog.load(sys.argv[2]) if e["wrapper"]=="model"))' "$here" "$EVLOG")" = "True"
expect pass "a successful spy call logs no stderr it never replayed" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=[x for x in wlog.load(sys.argv[2]) if x["wrapper"]=="spy"][-1]; print(e["exit"]==0 and e["stderr"]=="")' "$here" "$EVLOG")" = "True"
mkrun; cd "$tmp/run/repo"; printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/stubfail"; chmod +x "$tmp/bin/stubfail"
REAL_CODEX="$tmp/bin/stubfail" viawrap exec --json "prompt" >/dev/null 2>&1
expect pass "a silent Codex failure logs only the terminal message, no invented header" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[0]; print("Codex CLI said" not in e["stderr"] and "Treat as UNREVIEWED" in e["stderr"])' "$here" "$EVLOG")" = "True"

# r19: a quota error printed only on stderr is parsed from the merged stream like the wrapper does, once.
printf '#!/usr/bin/env bash\necho "ERROR: You have hit your usage limit." >&2\nexit 1\n' > "$tmp/bin/stderrquota"; chmod +x "$tmp/bin/stderrquota"
mkrun; cd "$tmp/run/repo"; REAL_CODEX="$tmp/bin/stderrquota" EXPECT_CODEX="$tmp/bin/stderrquota" viawrap exec --json "prompt" >/dev/null 2>&1
expect pass "a stderr-only quota error is logged once through the wrapper's Codex CLI said header" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[0]; print(e["stderr"].count("usage limit")==1 and "Codex CLI said" in e["stderr"])' "$here" "$EVLOG")" = "True"
expect pass "and it counts as the usage limit" env EXPECT_CODEX="$tmp/bin/stderrquota" python3 "$here/check-limit-hit.py" "$EVLOG"
# the final status, not history: an early incomplete audit followed by an approved fallback is not flagged.

# r20 to r33: the spy matches reviewer.sh's output contract (reviewer.sh:3,9,398): the reply is written to the output path once and
# nowhere else, and the event records that one reply. No alias detection: a caller wanting a file redirects the spy itself.
evalias() { python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); sp=[e for e in es if e["wrapper"]=="spy"]; print(len(sp)==1 and wlog.reply_text(sp[0]).count("VERDICT")<=1)' "$here" "$EVLOG"; }
evcount() { python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); sp=[e for e in es if e["wrapper"]=="spy"]; print(wlog.reply_text(sp[-1]).count("VERDICT") if len(sp)==1 else -1)' "$here" "$EVLOG"; }
evone() { python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); sp=[e for e in es if e["wrapper"]=="spy"]; md=[e for e in es if e["wrapper"]=="model"]; print(len(sp)==1 and len(md)==1 and wlog.reply_text(sp[0]).count("VERDICT")==1)' "$here" "$EVLOG"; }
spyrun() { bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$@"; }
for op in /dev/stdout /dev/fd/1; do
  mkrun; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
  got="$(spyrun "$op" 2>/dev/null)"
  expect pass "the reply appears once on stdout for output path $op" test "$(printf '%s\n' "$got" | grep -c '^VERDICT')" = 1
  expect pass "one event with one reply for $op" test "$(evone)" = True
done
mkrun; cd "$tmp/run/repo"; rm -f "$tmp/o.txt"
got="$(spyrun "$tmp/o.txt" 2>/dev/null)"
expect pass "a file output path gets the reply once and stdout stays empty" test "$(grep -c '^VERDICT' "$tmp/o.txt"):${#got}" = "1:0"
expect pass "one event with one reply for a file path" test "$(evone)" = True
mkrun; cd "$tmp/run/repo"
spyrun /dev/stderr >"$tmp/so.txt" 2>"$tmp/e.txt"; rc=$?
# WHY (r39): production reviewer.sh runs `run_sonnet 2>/dev/null` and does not accept /dev/stderr as an output file, so the real call delivers nothing.
expect pass "production delivers no reply to /dev/stderr and the launcher fails like it" test "$rc:$(cat "$tmp/so.txt" "$tmp/e.txt" | grep -c '^VERDICT')" != "0:1"
expect pass "and the event logs no verdict for /dev/stderr" test "$(evalias)" = True
# r31 (/dev/fd/3 3>&1), r32 (/dev/fd/5 and /dev/fd/6) and r33 (/dev/fd/0 0>&1): one delivery, one log entry each.
mkrun; cd "$tmp/run/repo"
got3="$(spyrun /dev/fd/3 3>&1 2>/dev/null)"
expect pass "r31: /dev/fd/3 as a dup of stdout delivers once" test "$(printf '%s\n' "$got3" | grep -c '^VERDICT')" = 1
# WHY 0 (r40): a pipe behind an alias cannot be read without consuming it, so no reply is logged and the checker fails closed.
expect pass "r31: the unobservable pipe delivery is not logged as a reply" test "$(evcount)" = 0
for n in 5 6; do
  mkrun; cd "$tmp/run/repo"; rm -f "$tmp/fd$n.txt"
  eval "spyrun /dev/fd/$n $n>\"$tmp/fd$n.txt\" >/dev/null 2>/dev/null"
  expect pass "r32: /dev/fd/$n lands once in the file behind that descriptor" test "$(grep -c '^VERDICT' "$tmp/fd$n.txt")" = 1
  # WHY 0 (r40): production reads the output back and macOS denies reading /dev/fd/N behind a write-only descriptor, so reviewer.sh itself exits 1; the log must not claim a clean review.
  expect pass "r32: production fails on the fd $n alias and no reply is logged" test "$(evcount)" = 0
done
mkrun; cd "$tmp/run/repo"
got0="$(spyrun /dev/fd/0 0>&1 2>/dev/null)"
expect pass "r33: /dev/fd/0 with 0>&1 delivers once" test "$(printf '%s\n' "$got0" | grep -c '^VERDICT')" = 1
expect pass "r33: the unobservable pipe delivery is not logged as a reply" test "$(evcount)" = 0

# r20: the reviewed patch must reproduce the final files from the baseline (hunk locations and context included).
orderfake() { python3 - "$1" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
fake = [r for r in rows if r["wrapper"] == "fake"]; rest = [r for r in rows if r["wrapper"] != "fake"]
fake[0]["ts"] = rest[0]["ts_start"] - 5; fake[0]["ts_start"] = fake[0]["ts"] - 1
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in fake + rest) + "\n")
open(sys.argv[1] + ".trunc", "w").write("\n".join(json.dumps(dict(r, input_text=(r["input_text"] or "").replace("plan line two", "")) if r["wrapper"] == "model" else r) for r in fake + rest) + "\n")
PY
}
# WHY fixed identities (CodeRabbit r43): commit-tree fails on a host with no git user configured.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
commitbase() { (cd "$tmp/run/repo" && git add -A >/dev/null 2>&1 && git update-ref HEAD "$(echo base | git commit-tree "$(git write-tree)")"); }
mkrun; cd "$tmp/run/repo"; printf 'k\nk\nk\ndef add(a, b):\n    return a + b\n' > app.py; commitbase
printf 'k\nNEW\nk\nk\ndef add(a, b):\n    return a + b\n' > app.py
git diff --no-color HEAD -- app.py > "$tmp/good.diff"
bash "$here/spy-reviewer.sh" S "$tmp/good.diff" "$tmp/out.txt" >/dev/null 2>&1; : > "$tmp/x"
line fake 1 unknown "$LIMIT"; orderfake "$EVLOG"
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
bash "$here/spy-reviewer.sh" S "$tmp/stale.diff" "$tmp/out.txt" >/dev/null 2>&1
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
  bash "$here/spy-reviewer.sh" S "$1" "$tmp/out.txt" >/dev/null 2>&1
  line fake 1 unknown "$LIMIT"; orderfake "$EVLOG"
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
mkrun; bash "$here/spy-reviewer.sh" S "$tmp/plan.md" /dev/stderr >"$tmp/so.txt" 2>"$tmp/se.txt"
expect pass "a reply to /dev/stderr never reaches the caller twice" test "$(cat "$tmp/so.txt" "$tmp/se.txt" | grep -c '^VERDICT')" -le 1
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
bash "$here/spy-reviewer.sh" S "$tmp/fmt.diff" "$tmp/out.txt" >/dev/null 2>&1
expect pass "an implementation formatted as def add (a, b): return (a + b) is phase implementation" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["phase"])' "$here" "$EVLOG")" = implementation
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
bash "$here/spy-reviewer.sh" S "$tmp/err.diff" /dev/stderr >/dev/null 2>&1
line fake 1 unknown "$LIMIT"; python3 - "$EVLOG" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; spy=[r for r in rows if r["wrapper"]=="spy"]; fake=[r for r in rows if r["wrapper"]!="spy"]
fake[0]["ts"]=spy[0]["ts_start"]-5; fake[0]["ts_start"]=fake[0]["ts"]-1
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in fake+spy)+"\n")
PY
expect fail "a review sent to /dev/stderr (lost in production) does not count as clean" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
expect fail "a report whose last non-blank line is a closing fence after the status is rejected" st $'```\nAUDIT-STATUS: APPROVED reviewer=codex\n```'

# r24: structural phase, no-stop clause mirrored, shim subcommand parsing, git add -N never adds every untracked file
mkrun; cd "$tmp/run/repo"
printf 'add = lambda a, b: a + b\n' > "$tmp/lam.py"; git diff --no-index --no-color /dev/null "$tmp/lam.py" > "$tmp/lam.diff"
bash "$here/spy-reviewer.sh" S "$tmp/lam.diff" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a lambda implementation is phase implementation" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["phase"])' "$here" "$EVLOG")" = implementation
mkdir -p "$tmp/tt"; printf 'def test_x():\n    def helper(a, b):\n        return a + b\n    assert helper(1, 2) == 3\n' > "$tmp/tt/test_app.py"; git diff --no-index --no-color /dev/null "$tmp/tt/test_app.py" > "$tmp/tt.diff"
mkrun; cd "$tmp/run/repo"; bash "$here/spy-reviewer.sh" S "$tmp/tt.diff" "$tmp/out.txt" >/dev/null 2>&1
expect pass "a tests-only diff containing return a + b is phase tests" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["phase"])' "$here" "$EVLOG")" = tests
cat > "$tmp/bin/stubok" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"T-real"}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"VERDICT: APPROVED"}}'
echo '{"type":"turn.completed"}'; exit 0
SH
chmod +x "$tmp/bin/stubok"
mkrun; cd "$tmp/run/repo"
REAL_CODEX="$tmp/bin/stubok" viawrap exec -p review --sandbox read-only --cd "$tmp/run/repo" --json --skip-git-repo-check "resume" >/dev/null 2>&1
expect pass "a new call whose prompt is the word resume is not logged as a resume" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["resume"])' "$here" "$EVLOG")" = "None"
REAL_CODEX="$tmp/bin/stubok" viawrap exec -p review --sandbox read-only --cd "$tmp/run/repo" resume --json --skip-git-repo-check T-real "again" >/dev/null 2>&1
expect pass "a real resume is logged with its thread id" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["resume"])' "$here" "$EVLOG")" = "T-real"
rm -rf "$tmp/mir"; mkdir -p "$tmp/mir"; cp -R "$here/../skills" "$here/../commands" "$tmp/mir/"
python3 - "$tmp/mir/commands/tdd-execute-codex.md" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a="Never conclude the reviewer is stuck"; assert a in s
open(p,"w").write(s.replace(a,"Always conclude the reviewer is stuck",1))
PY
expect fail "a reversed no-stop clause in one command copy is caught by the mirror test" python3 "$here/test-mirrors.py" "$tmp/mir"
rm -rf "$tmp/mir"; mkdir -p "$tmp/mir"; cp -R "$here/../skills" "$here/../commands" "$tmp/mir/"
sed -i.bak 's/`git add -N <each file this task created>`/`git add -N .`/' "$tmp/mir/skills/claude-codex/SKILL.md" && rm -f "$tmp/mir/skills/claude-codex/SKILL.md.bak"
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

# r26: mkrun never leaves the caller in a deleted directory, a folded quota stop rule is mirrored, an indented status line is rejected
rm -rf "$tmp/mir"; mkdir -p "$tmp/mir"; cp -R "$here/../skills" "$here/../commands" "$tmp/mir/"
python3 - "$tmp/mir/commands/tdd-claude-codex.md" <<'PY2'
import sys; p=sys.argv[1]; s=open(p).read()
a="a Codex usage limit or an unavailable CodeRabbit is never a blocker while tier S can run"; assert a in s
open(p,"w").write(s.replace(a,"a Codex usage limit is a blocker even while tier S can run",1))
PY2
expect fail "a folded failure paragraph that lets a usage limit stop the loop is caught" python3 "$here/test-mirrors.py" "$tmp/mir"
printf 'done\n\n    AUDIT-STATUS: APPROVED reviewer=codex\n' > "$tmp/ind.txt"
expect fail "an indented status line (a code block) is rejected" python3 "$here/audit-status.py" "$tmp/ind.txt"
printf 'done\n\nAUDIT-STATUS: APPROVED reviewer=codex\n' > "$tmp/ok.txt"
expect pass "an unindented status line is accepted" python3 "$here/audit-status.py" "$tmp/ok.txt" --expect APPROVED
mkrun; cd "$tmp/run/repo"; mkrun; expect pass "mkrun leaves the shell inside the recreated fixture" test "$(git rev-parse --show-toplevel)" = "$(cd "$tmp/run/repo" && git rev-parse --show-toplevel)"

# r27: the real scenario's resume check counts real-wrapper events only, for both the issuing and the resumed call
mkrun; line real 0 implementation 'THREAD_ID: abcdef12-3456\nVERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n'
python3 - "$EVLOG" <<'PY2'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
rows[0]["thread_id"]="abcdef12-3456"
r=dict(rows[0]); r.update(seq=2, wrapper="fake", resume="abcdef12-3456", ts=2)
rows.append(r); open(sys.argv[1],"w").write("\n".join(json.dumps(x) for x in rows)+"\n")
PY2
expect pass "a fake resume of a real thread passes the unrestricted resume check" python3 "$here/check-resume.py" "$EVLOG"
expect fail "a fake resume of a real thread fails the real-only resume check" python3 "$here/check-resume.py" "$EVLOG" --real
python3 - "$EVLOG" <<'PY2'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; rows[1]["wrapper"]="real"
open(sys.argv[1],"w").write("\n".join(json.dumps(x) for x in rows)+"\n")
PY2
expect pass "a real resume of a real thread passes the real-only resume check" python3 "$here/check-resume.py" "$EVLOG" --real
# cc11-main-r2 finding 4: a Codex approval that lacks the four severity lines is not a valid verdict (the skills define the whole block).
mkrun; line real 0 implementation 'THREAD_ID: abcdef12-3456\nVERDICT: APPROVED\n'
expect fail "a real Codex approval with no severity lines is not a valid verdict" python3 "$here/check-real-basic.py" "$EVLOG" verdict
mkrun; line real 0 implementation 'THREAD_ID: abcdef12-3456\nVERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nLOW: none\n'
expect fail "a real Codex approval missing the MEDIUM line is not a valid verdict" python3 "$here/check-real-basic.py" "$EVLOG" verdict
mkrun; line real 0 implementation 'THREAD_ID: abcdef12-3456\nVERDICT: BLOCKED\nCRITICAL: bad thing\nHIGH: none\nMEDIUM: none\nLOW: none\n'
expect pass "a complete BLOCKED block with a finding is a valid verdict" python3 "$here/check-real-basic.py" "$EVLOG" verdict
mkrun; line real 0 implementation 'THREAD_ID: abcdef12-3456\nVERDICT: APPROVED\n'
python3 - "$EVLOG" <<'PY2'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
rows[0]["thread_id"]="abcdef12-3456"
r=dict(rows[0]); r.update(seq=2, resume="abcdef12-3456", ts=2)
rows.append(r); open(sys.argv[1],"w").write("\n".join(json.dumps(x) for x in rows)+"\n")
PY2
expect fail "a real resume whose approval lacks the severity lines does not count" python3 "$here/check-resume.py" "$EVLOG" --real

# r28/r29: provenance of real runs comes from the process table, the wrapper hash, the run nonce and the real binary path
cat > "$tmp/realbin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"abcdef12-3456"}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none"}}'
echo '{"type":"turn.completed"}'; exit 0
SH
chmod +x "$tmp/realbin/codex"
wrapper_kind() { python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["wrapper"])' "$here" "$EVLOG"; }
mkrun
REAL_CODEX="$tmp/realbin/codex" bash "$here/shim/codex" exec --json "prompt" >/dev/null 2>&1
expect pass "a bare codex exec call is logged as direct, not real" test "$(wrapper_kind)" = direct
expect fail "a bare codex exec call does not satisfy the real thread check" python3 "$here/check-real-basic.py" "$EVLOG" thread
bash -c "REAL_CODEX='$tmp/realbin/codex' bash '$here/shim/codex' exec --json 'codex-call.sh'; true # codex-call.sh" >/dev/null 2>&1
expect pass "a bare call whose parent command text mentions codex-call.sh is still direct" test "$(wrapper_kind)" = direct
REAL_CODEX="$tmp/realbin/codex" viawrap exec --json "prompt" >/dev/null 2>&1
expect pass "a call made by the reviewed codex-call.sh is logged as real" test "$(wrapper_kind)" = real
expect pass "that call satisfies the real thread check" python3 "$here/check-real-basic.py" "$EVLOG" thread
expect pass "that call satisfies the real verdict check" python3 "$here/check-real-basic.py" "$EVLOG" verdict
mkrun; bash -c "exec 255<'$tmp/wrap/codex-call.sh'; REAL_CODEX='$tmp/realbin/codex' bash '$here/shim/codex' exec --json prompt; true" >/dev/null 2>&1
expect pass "a bare caller that opened the wrapper on fd 255 itself is logged as direct" test "$(wrapper_kind)" = direct
expect fail "that fd 255 spoof does not satisfy the real thread check" python3 "$here/check-real-basic.py" "$EVLOG" thread
mkrun; mkdir -p "$tmp/wrap2"; { cat "$tmp/wrap/codex-call.sh"; echo '# edited copy'; } > "$tmp/wrap2/codex-call.sh"
REAL_CODEX="$tmp/realbin/codex" bash "$tmp/wrap2/codex-call.sh" exec --json "prompt" >/dev/null 2>&1
expect pass "an edited copy of the wrapper is logged as direct" test "$(wrapper_kind)" = direct
mkrun; REAL_CODEX="$tmp/realbin/codex" EVNONCE=other viawrap exec --json "prompt" >/dev/null 2>&1
expect fail "a run stamped with a different nonce is rejected by the checker" python3 "$here/check-real-basic.py" "$EVLOG" thread
mkrun; cp "$tmp/realbin/codex" "$tmp/shimcopy"; mkdir -p "$tmp/xs/shim"; cp "$tmp/realbin/codex" "$tmp/xs/shim/codex"
REAL_CODEX="$tmp/xs/shim/codex" viawrap exec --json "prompt" >/dev/null 2>&1
expect fail "a run whose codex binary is not the expected real one is rejected" python3 "$here/check-real-basic.py" "$EVLOG" thread
mkrun; line fake 0 unknown 'THREAD_ID: abcdef12-3456\nVERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n'
expect fail "a fake wrapper reply does not satisfy the real verdict check" python3 "$here/check-real-basic.py" "$EVLOG" verdict
mkdir -p "$tmp/sh1" "$tmp/sh2"; printf 'def add(a, b):\n    return a + b\n' > "$tmp/sh1/app.py"; : > "$tmp/sh1/test_app.py"
: > "$tmp/sh2/app.py"; printf 'def add(a, b):\n    return a + b\n' > "$tmp/sh2/test_app.py"
expect pass "moving add() into the test file changes the state hash" test "$(python3 "$here/state-hash.py" "$tmp/sh1")" != "$(python3 "$here/state-hash.py" "$tmp/sh2")"
mkrun; line fake 1 unknown 'codex-call: Codex CLI said:\nno saved session found with ID usage limit\n'
expect fail "an echoed argument named usage limit is not a quota error" python3 "$here/check-limit-hit.py" "$EVLOG"
mkrun; line fake 1 unknown "$LIMIT"
expect pass "a real quota sentence is a quota error" python3 "$here/check-limit-hit.py" "$EVLOG"

# r29: diagnose is not a review, and the fallback must carry the production argument vector
mkrun; cd "$tmp/run/repo"; printf 'k\ndef add(a, b):\n    return a + b\n' > app.py; commitbase
printf 'k\nNEW\ndef add(a, b):\n    return a + b\n' > app.py; git diff --no-color HEAD -- app.py > "$tmp/d.diff"
bash "$here/spy-reviewer.sh" diagnose "$tmp/d.diff" "$tmp/out.txt" >/dev/null 2>&1; src=$?
expect pass "the spy refuses the diagnose tier" test "$src" -ne 0
mkrun; cd "$tmp/run/repo"; printf 'k\ndef add(a, b):\n    return a + b\n' > app.py; commitbase
printf 'k\nNEW\ndef add(a, b):\n    return a + b\n' > app.py
python3 - "$EVLOG" <<'PY2'
import json,sys
rows=[]
def ev(w,code,argv,ts,out=""): return {"seq":len(rows)+1,"wrapper":w,"prov":None,"argv":argv,"exit":code,"resume":None,"thread_id":None,"phase":"implementation","stdout":out,"stderr":"","input_sha256":"","input_bytes":0,"input_text":"","tree_sha256":None,"meta":{},"ts_start":ts,"ts":ts+1}
rows.append(ev("fake",1,[],1,"ERROR: You have hit your usage limit.\n"))
rows.append(ev("spy",0,["diagnose","f"],10,"VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n"))
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PY2
expect fail "a diagnose invocation does not pass the fallback check" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation

# r31: forged argv[0], deleted helper module, an output path that is a dup of the caller's stdout
mkrun; W="$tmp/wrap/codex-call.sh"
( exec -a "bash $W" bash -c "exec 255<'$W'; REAL_CODEX='$tmp/realbin/codex' bash '$here/shim/codex' exec --json prompt; true" ) >/dev/null 2>&1
expect pass "a shell with argv[0] forged to run the wrapper (really -c) is logged as direct" test "$(wrapper_kind)" = direct
expect fail "the forged argv[0] does not satisfy the real thread check" python3 "$here/check-real-basic.py" "$EVLOG" thread
mkdir -p "$tmp/sh3"; printf 'import helper\n' > "$tmp/sh3/app.py"; printf 'X=1\n' > "$tmp/sh3/helper.py"; before="$(python3 "$here/state-hash.py" "$tmp/sh3")"; rm "$tmp/sh3/helper.py"
expect pass "deleting an imported helper module changes the state hash" test "$before" != "$(python3 "$here/state-hash.py" "$tmp/sh3")"

# r38: the launcher runs the REAL reviewer.sh, so production decides tier, base and committed-state rules; the checker asserts what ran.
commit2() { (cd "$tmp/run/repo" && git add -A >/dev/null 2>&1 && git update-ref HEAD "$(echo next | git commit-tree "$(git write-tree)" -p HEAD)"); }
rrun() { # committed edit on top of the root commit; REVIEW_BASE_SHA is R0 = the root commit
  mkrun; cd "$tmp/run/repo"; printf 'x=1\n' > app.py; commitbase; R0="$(git rev-parse HEAD)"; line fake 1 unknown "$LIMIT"
  printf 'x=1\ndef add(a, b):\n    return a + b\n' > app.py; commit2; printf 'in\n' > "$tmp/rin.txt"
}
rrun; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1
expect pass "production accepts tier R with a base and the CodeRabbit fake ran on committed state" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); m=[e for e in es if e["wrapper"]=="model"][-1]; print(m["meta"]["bin"], m["meta"]["tier"], m["meta"]["dirty"], m["meta"]["base"]==sys.argv[3])' "$here" "$EVLOG" "$R0")" = "coderabbit R 0 True"
orderfake "$EVLOG"
expect pass "a clean tier R review of committed state is accepted for the code" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
expect fail "a tier R review never validates a plan file" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/rin.txt"
printf 'x=1\ndef add(a, b):\n    return a - b\n' > app.py
expect fail "code edited after the R review is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
rrun; printf 'x=1\ndef add(a, b):\n    return a - b\n' > app.py
REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1
expect pass "production lets tier R review while uncommitted changes exist (the fake records dirty=1)" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); print([e for e in es if e["wrapper"]=="model"][-1]["meta"]["dirty"])' "$here" "$EVLOG")" = 1
orderfake "$EVLOG"
expect fail "a tier R review with uncommitted changes is rejected by the checker" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
rrun; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1
orderfake "$EVLOG"
expect pass "a committed R review is accepted before a new file appears" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
printf 'def sneaky():\n    return 1\n' > "$tmp/run/repo/new_untracked.py"
expect fail "an untracked .py file no commit holds is rejected (r39)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
rm -f "$tmp/run/repo/new_untracked.py"
rrun; printf 'def sneaky():\n    return 1\n' > "$tmp/run/repo/new_untracked.py"; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1
expect pass "the CodeRabbit fake records an untracked .py as dirty" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print([e for e in wlog.load(sys.argv[2]) if e["wrapper"]=="model"][-1]["meta"]["dirty"])' "$here" "$EVLOG")" = 1
orderfake "$EVLOG"
expect fail "an untracked .py present at review time is rejected by the checker (r39)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
# r41: a --version call is not a review, and a CRLF committed diff is still accepted
mkrun; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"; line fake 1 unknown "$LIMIT"; bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"
python3 - "$EVLOG" "$tmp/evV.jsonl" <<'PYV'
import json, sys
out = open(sys.argv[2], "w")
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["wrapper"] == "model": e["argv"].insert(0, "--version")
    out.write(json.dumps(e) + "\n")
PYV
expect fail "a claude call carrying --version is not accepted as a review (r41)" python3 "$here/check-reviewer-after-limit.py" "$tmp/evV.jsonl" --plan-file "$tmp/plan.md"
expect pass "the unmodified claude review is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
mkrun; cd "$tmp/run/repo"; out="$(PATH="$here/fake-models:$PATH" claude --version "x" 2>&1)"; rc=$?
expect pass "the fake claude refuses a --version call" test "$rc" != 0
rrun; printf 'x = 1\r\ny = 2\r\n' > "$tmp/run/repo/crlf.py"; commit2
REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"
expect pass "a committed CRLF diff is accepted (r41)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
# r40: the review type must be committed, and an IGNORED .py module counts as unreviewed code too
rrun; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"
python3 - "$EVLOG" "$tmp/evU.jsonl" <<'PYU'
import json, sys
out = open(sys.argv[2], "w")
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["wrapper"] == "model" and "-t" in e["argv"]: e["argv"][e["argv"].index("-t") + 1] = "uncommitted"
    out.write(json.dumps(e) + "\n")
PYU
expect fail "a CodeRabbit run of -t uncommitted does not validate committed code (r40)" python3 "$here/check-reviewer-after-limit.py" "$tmp/evU.jsonl" --repo "$tmp/run/repo"
rrun; printf 'node_modules\nsecret_mod.py\n' > "$tmp/run/repo/.gitignore"; printf 'def hidden():\n    return 2\n' > "$tmp/run/repo/secret_mod.py"
REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"
expect fail "an ignored untracked .py module present at review time is rejected (r40)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
rrun; bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect pass "production rejects tier R without REVIEW_BASE_SHA (exit 2, no clean review)" test "$rc" = 2
orderfake "$EVLOG"
expect fail "and the checker finds no clean fallback review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG"
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan line one\nplan line two\n' > "$tmp/plan.md"
bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
orderfake "$EVLOG"
expect pass "a tier S plan review with the full file in the model prompt is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
expect fail "a model prompt missing part of the plan is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG.trunc" --plan-file "$tmp/plan.md"
# FIFO evidence (r37): the launcher opens the caller's output path once, so a one-shot reader gets the reply and nothing hangs.
mkrun; cd "$tmp/run/repo"; rm -f "$tmp/ff"; mkfifo "$tmp/ff"; printf 'plan\n' > "$tmp/plan.md"
( tmo 20 cat "$tmp/ff" > "$tmp/ff.out" ) & rd=$!
tmo 60 bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/ff" >/dev/null 2>&1; frc=$?; wait $rd
expect pass "r37 FIFO: the launcher finishes against a one-shot FIFO reader which gets the reply exactly once" test "$frc:$(grep -c '^VERDICT' "$tmp/ff.out")" = "0:1"
expect pass "and the unobservable FIFO delivery is not logged as a reply" test "$(evcount)" = 0
# fidelity link: a change to PRODUCTION reviewer.sh validation changes what the suite sees, with the launcher untouched.
# WHY a helper script that honors SPY_CONFIG_DIR (cc11-main-r1): the copy used to read from $HOME, so an otherwise valid override still needed the real installed config.
bash "$here/copy-config.sh" "$tmp/cfg"
expect pass "the production-mutation copy honors SPY_CONFIG_DIR and never reads HOME" env HOME="$tmp/no-home" SPY_CONFIG_DIR="${SPY_CONFIG_DIR:-$HOME/.claude/config}" bash "$here/copy-config.sh" "$tmp/cfg-home-test"
sed -i.bak 's/^  E|R|S|diagnose) ;;$/  E|R|diagnose) ;;/' "$tmp/cfg/scripts/reviewer.sh"
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
SPY_CONFIG_DIR="$tmp/cfg" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect pass "with production validation changed to reject tier S the unchanged launcher fails" test "$rc" = 1
orderfake "$EVLOG"
expect fail "and the checker sees no clean fallback review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"

# r34: an unwritable output path delivers nothing and the event must not log the reply
mkrun; cd "$tmp/run/repo"
spyrun "$tmp/no-such-dir/o.txt" >/dev/null 2>&1; rc=$?
expect pass "an unwritable output path fails the spy" test "$rc" != 0
expect pass "and the event stderr holds the outage message once" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[-1]; print(e["stderr"].count("UNAVAILABLE"))' "$here" "$EVLOG")" = 1
expect pass "and the event logs no reply" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); print(len([x for x in es if x["wrapper"]=="spy"])==1 and "VERDICT" not in wlog.reply_text(es[-1]))' "$here" "$EVLOG")" = True

# r36: a quota reply from a bare direct codex call does not anchor the after-limit ordering, and a missing clause in a command is caught
mkrun; line direct 1 unknown "$LIMIT"; line spy 0 implementation "$CLEANR"
expect fail "a direct (non-wrapper) quota event is not a usage limit anchor" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
expect fail "and check-limit-hit does not count it" python3 "$here/check-limit-hit.py" "$EVLOG"
rm -rf "$tmp/mir"; mkdir -p "$tmp/mir"; cp -R "$here/../skills" "$here/../commands" "$tmp/mir/"
python3 - "$tmp/mir/commands/tdd-execute-codex.md" <<'PY2'
import re, sys; p=sys.argv[1]; s=open(p).read()
n = len(re.findall(r"\(a call that merely died", s))
assert n >= 1
open(p,"w").write(s.replace("(a call that merely died", "(a Codex usage limit is always a blocker; a call that merely died"))
PY2
expect fail "a command whose quota clause no longer matches is caught by the mirror test" python3 "$here/test-mirrors.py" "$tmp/mir"

# r37: a named FIFO destination is opened once, so the reader does not see an early EOF and the spy does not block
mkrun; cd "$tmp/run/repo"; rm -f "$tmp/ff"; mkfifo "$tmp/ff"
( cat "$tmp/ff" > "$tmp/ff.got" ) & rpid=$!
python3 - "$here/spy-reviewer.sh" "$tmp/bin" "$tmp/run/spy.log" "$tmp/plan.md" "$tmp/ff" <<'PYF'
import os, subprocess, sys
spy, b, log, plan, ff = sys.argv[1:6]
env = dict(os.environ, PATH=b + ":" + os.environ["PATH"], SPY_LOG=log)
try:
    r = subprocess.run(["bash", spy, "S", plan, ff], env=env, timeout=240, capture_output=True)
    sys.exit(r.returncode)
except subprocess.TimeoutExpired:
    sys.exit(99)
PYF
frc=$?; kill "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null
expect pass "the spy completes against a named FIFO reader" test "$frc" = 0
expect pass "and the reader got the reply once" test "$(grep -c '^VERDICT' "$tmp/ff.got")" = 1

# r42 (CodeRabbit): check-impl needs proof the asserts ran, a rename counts its new path, and each wrapper has one clean form
printf 'import os\nos._exit(0)\n' > "$tmp/exit0.py"; printf 'def add(a, b):\n    return a + b\n' > "$tmp/good.py"
expect fail "a module that exits 0 on import is not a passing implementation" python3 "$here/check-impl.py" "$tmp/exit0.py"
expect pass "a real add passes check-impl" python3 "$here/check-impl.py" "$tmp/good.py"
expect pass "a rename from test_app.py to app.py is the implementation phase" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import evlog; print(evlog.phase_of("diff --git a/test_app.py b/app.py\nsimilarity index 90%\nrename from test_app.py\nrename to app.py\n"))' "$here")" = implementation
expect fail "the Codex-form clean reply is not a clean reviewer.sh spy reply" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; sys.exit(0 if wlog.is_clean({"wrapper":"spy","exit":0,"stdout":"VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n","stderr":""}) else 1)' "$here"

mkdir -p "$tmp/em"; for m in mathops strops listops pkginfo; do printf 'import os\nos._exit(0)\n' > "$tmp/em/$m.py"; done
expect fail "four modules that exit 0 on import do not pass check-modules" python3 "$here/check-modules.py" "$tmp/em"

# r44: a clean review followed by a malformed review attempt is not approved
rrun; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"
expect pass "the clean tier R review is accepted before a malformed call" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
sleep 1; bash "$here/spy-reviewer.sh" Z "$tmp/rin.txt" "$tmp/out2.txt" >/dev/null 2>&1
expect fail "a malformed review call after the clean one is the final event and is rejected (r44)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
bash "$here/spy-reviewer.sh" diagnose "$tmp/rin.txt" "$tmp/out3.txt" >/dev/null 2>&1
expect fail "a diagnose call does not rescue it" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"

# r45: production caches a tier R verdict by input hash, so a repeat after a new commit may return the old approval with no model run
rrun; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1
printf 'x=1\ndef add(a, b):\n    return a + b\ndef sub(a, b):\n    return a - b\n' > "$tmp/run/repo/app.py"; commit2
sleep 1; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out2.txt" >/dev/null 2>&1
expect pass "the repeat review on unchanged input runs through the same private cache as production" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); sp=[e for e in es if e["wrapper"]=="spy"]; md=[e for e in es if e["wrapper"]=="model"]; print(len(sp), len(md))' "$here" "$EVLOG")" = "2 1"
orderfake "$EVLOG"
expect fail "a cached approval with no model run behind it is rejected for the new commit (r45)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"

# r46: the launcher must behave like a direct production call for stream aliases (pipes stay pipes)
for op in /dev/stdout /dev/fd/1 /dev/stderr; do
  mkrun; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"; mkdir -p "$tmp/dh"
  # WHY the real config path is fixed first: in one assignment list `HOME=... CLAUDE_CONFIG_DIR=$HOME/...` would expand against the NEW HOME.
  cfg="${SPY_CONFIG_DIR:-$HOME/.claude/config}"
  d_out="$(HOME="$tmp/dh" CLAUDE_CONFIG_DIR="$cfg" PATH="$here/fake-models:$PATH" EVLOG="$tmp/direct.jsonl" bash "$cfg/scripts/reviewer.sh" S "$tmp/plan.md" "$op" 2>/dev/null)"; d_rc=$?
  [[ -n "${CHECKERS_NO_SPY:-}" ]] && : > "$spymark"
  s_out="$(spyrun "$op" 2>/dev/null)"; s_rc=$?
  expect pass "direct production and the launcher agree on rc and stdout for $op (r46)" test "$d_rc:$d_out" = "$s_rc:$s_out"
done

# r47 (CodeRabbit): model-time tree digest must match, the suite names its prerequisite, ordering keeps model events after the quota
rrun; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"
python3 - "$EVLOG" "$tmp/evT.jsonl" <<'PYT'
import json, sys
out = open(sys.argv[2], "w")
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["wrapper"] == "model": e["meta"]["tree"] = "0" * 64
    out.write(json.dumps(e) + "\n")
PYT
expect fail "a CodeRabbit review whose model-time tree digest differs from the launcher's is rejected (r47)" python3 "$here/check-reviewer-after-limit.py" "$tmp/evT.jsonl" --repo "$tmp/run/repo"
expect pass "a model event keeps its place after the quota event once the quota is ordered" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); q=[e for e in es if e["wrapper"]=="fake"][0]; print(all(e["ts"]>q["ts"] for e in es if e["wrapper"]=="model"))' "$here" "$EVLOG")" = True
[[ -n "${CHECKERS_NO_SPY:-}" ]] && : > "$spymark"  # the prerequisite check is itself skipped in this mode
expect fail "the suite stops with a clear line when the installed reviewer.sh is missing" env SPY_CONFIG_DIR="$tmp/no-such-config" bash "$here/test-checkers.sh"

# cc11-main-r1: the portable timeout stand-in kills a slow command with 124 and passes through a fast command's status
expect pass "tmo python fallback kills a slow command with exit 124" test "$(TMO_FORCE_PY=1 tmo 1 sleep 5 >/dev/null 2>&1; echo $?)" = 124
expect pass "tmo python fallback passes through the command exit status" test "$(TMO_FORCE_PY=1 tmo 5 bash -c 'exit 3' >/dev/null 2>&1; echo $?)" = 3

# cc11-main-r1: tier S fallback must work in a repo with NO origin remote and for a scratch plan in a folder that is not a repo
# (scripts/codex-call.sh runs plan audits from scratch folders). The review-loop-proof fixture used to add an origin because an older
# reviewer.sh exited without one; the real reviewer.sh must now succeed, and so must the fixture, without it.
mkrun; (cd "$tmp/run/repo" && git remote remove origin); line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
spyrun "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect pass "tier S fallback succeeds in a repo with no origin remote" test "$rc" = 0
orderfake "$EVLOG"
expect pass "and the checker sees the clean fallback review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
mkrun; line fake 1 unknown "$LIMIT"; rm -rf "$tmp/scratch"; mkdir -p "$tmp/scratch"; cd "$tmp/scratch"; printf 'plan\n' > "$tmp/plan.md"
spyrun "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect pass "tier S fallback succeeds for a scratch plan outside any git repo" test "$rc" = 0
# mutation proof source: a reviewer.sh that exits when there is no origin (the old behavior) must make the first case fail
bash "$here/copy-config.sh" "$tmp/cfg-noorigin"
sed -i.bak 's|^_rq_slug=\$(git -C "\$REPO_ROOT" remote get-url origin.*$|git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>\&1 \|\| exit 9; _rq_slug=x|' "$tmp/cfg-noorigin/scripts/reviewer.sh"
mkrun; (cd "$tmp/run/repo" && git remote remove origin); line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
SPY_CONFIG_DIR="$tmp/cfg-noorigin" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect pass "control: an origin-requiring reviewer.sh makes the no-remote case fail (the test can detect the old bug)" test "$rc" = 9

[[ -n "${CHECKERS_NO_SPY:-}" ]] && echo "CHECKERS_NO_SPY=1: skipped $skipped spy-reviewer case(s); they need the installed reviewer.sh"
exit $fail
