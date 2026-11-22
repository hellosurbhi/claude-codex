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
# CHECKERS_NO_SPY=1 spy-reviewer.sh and copy-config.sh exit 0 without doing anything, and only cases written as `expect_spy` (the ones that call the
# spy or assert on what it produced) are skipped and counted. Plain `expect` NEVER skips: an earlier sticky marker skipped every case that followed
# a spy call in the same run, which hid unrelated secret-guard, CI-config and wrapper checks in public CI. The self-test at the end fails when a
# named non-spy case did not run, so a case wrongly written as expect_spy cannot hide.
skipped=0; plain_ran=0; ran_names=""
expect_run() { local want="$1" name="$2"; shift 2; "$@" >/dev/null 2>&1; local rc=$?; plain_ran=$((plain_ran+1)); if { [[ $want == pass && $rc -eq 0 ]] || [[ $want == fail && $rc -ne 0 ]]; }; then ran_names+="$name"$'\n'; ok "$name"; else bad "$name (rc=$rc, wanted $want)"; fi; }
expect() { expect_run "$@"; }
expect_spy() { if [[ -n "${CHECKERS_NO_SPY:-}" ]]; then skipped=$((skipped+1)); echo "SKIP: $2"; return 0; fi; expect_run "$@"; }
# cc11-main-r2 finding 6: the python3 timeout stand-in must kill the whole process group, not only its child, or a timed-out launcher leaves reviewer and tee processes running.
mkdir -p "$tmp/tmo"; rm -f "$tmp/tmo/gpid"
TMO_FORCE_PY=1 tmo 1 bash -c 'sleep 60 & echo $! > "$1"; wait' _ "$tmp/tmo/gpid" >/dev/null 2>&1; tmo_rc=$?
sleep 1
expect pass "the python3 timeout stand-in exits 124 on expiry" test "$tmo_rc" -eq 124
expect fail "the python3 timeout stand-in leaves no grandchild running after expiry" kill -0 "$(cat "$tmp/tmo/gpid" 2>/dev/null || echo 99999999)"
kill "$(cat "$tmp/tmo/gpid" 2>/dev/null)" >/dev/null 2>&1 || true  # tidy up when the case above failed
gdiff() { local f; for f in "$@"; do git diff --no-index --no-color /dev/null "$f"; done; }
mkrun() { cd "$tmp"; rm -rf "$tmp/run"; mkdir -p "$tmp/run/repo"; (cd "$tmp/run/repo" && git init -q && git remote add origin https://example.invalid/t/r.git && printf 'x=1\n' > app.py); cd "$tmp/run/repo"; export EVLOG="$tmp/run/wrapper.jsonl" FAKE_LOG="$tmp/run/calls.log"; : > "$EVLOG"; : > "$FAKE_LOG"; unset FAKE_LIMIT FAKE_FAIL_FIRST; export FAKE_ROUNDS=0; }
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
if os.environ.get("LINEMETA") and wrapper != "spy":
    ev["meta"] = dict(kv.split("=", 1) for kv in os.environ["LINEMETA"].split())
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
realgit="$(command -v git)"; mkdir -p "$tmp/stubgit"; printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "$FAILSUB" ] && exit 1; done\nexec "%s" "$@"\n' "$realgit" > "$tmp/stubgit/git"; chmod +x "$tmp/stubgit/git"
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
expect_spy pass "spy logs the reviewed plan sha (event carries input_sha256 of the file)" test "$(python3 -c 'import sys,hashlib,json; sys.path.insert(0,sys.argv[1]); import wlog; e=[x for x in wlog.load(sys.argv[2]) if x["wrapper"]=="spy"]; print(bool(e) and e[-1]["input_sha256"]==hashlib.sha256(open(sys.argv[3],"rb").read()).hexdigest())' "$here" "$EVLOG" "$tmp/plan.md")" = "True"
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
# Round 3 finding 2: ONE grammar function (wlog.verdict_state) judges every verdict: clean / findings / no-verdict.
gstate() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; print(wlog.verdict_state(sys.argv[2]))' "$here" "$1"; }
expect pass "grammar: a bare APPROVED is clean" test "$(gstate $'VERDICT: APPROVED\n')" = clean
expect pass "grammar: APPROVED plus HIGH: none is clean" test "$(gstate $'VERDICT: APPROVED\nHIGH: none\n')" = clean
expect pass "grammar: placeholders in any case with a trailing period are clean" test "$(gstate $'VERDICT: APPROVED\nCRITICAL: None.\nHIGH: N/A\nMEDIUM: n/a.\nLOW: NONE\n')" = clean
expect pass "grammar: APPROVED plus a real MEDIUM is findings" test "$(gstate $'VERDICT: APPROVED\nMEDIUM: missing null check in a.py:3\n')" = findings
expect pass "grammar: APPROVED plus a real CRITICAL is findings" test "$(gstate $'VERDICT: APPROVED\nCRITICAL: secret committed\n')" = findings
expect pass "grammar: APPROVED plus a real HIGH among placeholders is findings" test "$(gstate $'VERDICT: APPROVED\nCRITICAL: none\nHIGH: data loss on retry\nMEDIUM: none\nLOW: none\n')" = findings
expect pass "grammar: a header with its text on the next line is findings" test "$(gstate $'VERDICT: APPROVED\nHIGH:\nthe retry loop never stops\n')" = findings
expect pass "grammar: a header whose next line is a placeholder is clean" test "$(gstate $'VERDICT: APPROVED\nHIGH:\nnone\n')" = clean
# cc11-main-r4 finding 3: a severity header with empty text and no non-header line after it is a possibly truncated finding, so it is no verdict, never clean.
expect pass "grammar: APPROVED then an empty HIGH: at the end of the output is no verdict" test "$(gstate $'VERDICT: APPROVED\nHIGH:\n')" = no-verdict
expect pass "grammar: APPROVED then an empty HIGH: then MEDIUM with real text is no verdict" test "$(gstate $'VERDICT: APPROVED\nHIGH:\nMEDIUM: real text\n')" = no-verdict
expect pass "grammar: APPROVED then HIGH: with its text on the next line is findings" test "$(gstate $'VERDICT: APPROVED\nHIGH:\nrace in the cache\n')" = findings
expect pass "grammar: APPROVED then HIGH: none is clean" test "$(gstate $'VERDICT: APPROVED\nHIGH: none\n')" = clean
expect pass "grammar: two empty headers in a row are no verdict" test "$(gstate $'VERDICT: APPROVED\nCRITICAL:\nHIGH:\n')" = no-verdict
expect pass "grammar: BLOCKED with no finding at all is findings (never clean)" test "$(gstate $'VERDICT: BLOCKED\n')" = findings
expect pass "grammar: stray prose after APPROVED is findings (never clean)" test "$(gstate $'VERDICT: APPROVED\nlooks fine to me\n')" = findings
expect pass "grammar: BLOCKED with a finding is findings" test "$(gstate $'VERDICT: BLOCKED\nCRITICAL: bad\n')" = findings
expect pass "grammar: two verdict lines is no verdict" test "$(gstate $'VERDICT: APPROVED\nVERDICT: BLOCKED\n')" = no-verdict
expect pass "grammar: NOT APPROVED is no verdict" test "$(gstate $'VERDICT: NOT APPROVED\n')" = no-verdict
expect pass "grammar: a verdict word inside other text is no verdict" test "$(gstate $'Looks good. VERDICT: APPROVED\n')" = no-verdict
expect pass "grammar: a qualified APPROVED is no verdict" test "$(gstate $'VERDICT: APPROVED once you fix the null check\n')" = no-verdict
expect pass "grammar: the verdict must be the first non-blank line" test "$(gstate $'Review below.\nVERDICT: APPROVED\n')" = no-verdict
expect pass "grammar: empty output is no verdict" test "$(gstate '')" = no-verdict
expect pass "grammar: whitespace only is no verdict" test "$(gstate $'  \n\n')" = no-verdict
expect pass "grammar: leading blank lines before the verdict are fine" test "$(gstate $'\n\nVERDICT: APPROVED\n')" = clean
expect fail "an APPROVED with a real CRITICAL is not a clean wrapper event" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; sys.exit(0 if wlog.is_clean({"wrapper":"real","exit":0,"stdout":"THREAD_ID: t\nVERDICT: APPROVED\nCRITICAL: bad\n","stderr":""}) else 1)' "$here"
expect pass "a bare APPROVED from the real wrapper is a clean wrapper event" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; sys.exit(0 if wlog.is_clean({"wrapper":"real","exit":0,"stdout":"THREAD_ID: t\nVERDICT: APPROVED\n","stderr":""}) else 1)' "$here"
expect fail "a clean verdict with a nonzero exit is not clean" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; sys.exit(0 if wlog.is_clean({"wrapper":"real","exit":1,"stdout":"THREAD_ID: t\nVERDICT: APPROVED\n","stderr":""}) else 1)' "$here"
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
expect_spy pass "the failed spy call with a missing input is logged" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2]); print(len(e)==4 and e[-1]["exit"]!=0)' "$here" "$EVLOG")" = "True"
expect_spy fail "a later failed review means the last review is not clean" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation
# an unchanged CRLF plan hashes by raw bytes and matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan line\r\nsecond\r\n' > "$tmp/plan.md"
bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "an unchanged CRLF plan matches the reviewed digest" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
# r37: a tier R review is of committed repository state, so it never validates a plan file
python3 - "$EVLOG" "$tmp/evR.jsonl" <<'PYR'
import json, sys
out = open(sys.argv[2], "w")
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["wrapper"] == "spy": e["argv"][0] = "R"
    out.write(json.dumps(e) + "\n")
PYR
expect_spy fail "a tier R spy review does not validate the plan file" python3 "$here/check-reviewer-after-limit.py" "$tmp/evR.jsonl" --plan-file "$tmp/plan.md"
# the event describes the snapshot, so a plan edited DURING the review no longer matches.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan v1\n' > "$tmp/plan.md"
EDIT_DURING="$tmp/plan.md" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect_spy fail "a plan edited while it was being reviewed is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
# the clean review is bound to the exact final .py state (paths, bytes, indentation, other modules, deletions).
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"
printf 'x=1\ndef add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a - b\n' > other.py
gdiff app.py other.py > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
cp "$tmp/run/repo/app.py" "$tmp/app.good"
expect_spy pass "reviewed final code state is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
# r12 finding 3: a failing git call inside this checker must fail it, not leave an empty result that the rest of the checks accept
# the fixture repo has no commit yet (no root commit is legitimate then), so give it an empty root commit: these git calls only run when a root exists
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$(printf 'root\n\nVerified: fixture repo for the failing-git cases')"
expect_spy pass "reviewed final code state is still accepted once the repo has a root commit" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
for sub in rev-list ls-tree; do
  expect_spy fail "a failing git $sub fails the reviewed-state check" env FAILSUB=$sub PATH="$tmp/stubgit:$PATH" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
done
printf 'def evil():\n    pass\n' >> app.py
expect_spy fail "code edited after the approval is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
cp "$tmp/app.good" app.py; printf 'def sub(a, b):\n    return a - b - 1\n' > other.py
expect_spy fail "an edit to ANOTHER module after the approval is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
printf 'def sub(a, b):\n    return a - b\n' > other.py; sed -i.bak 's/^    return/        return/' app.py; rm -f app.py.bak
expect_spy fail "an indentation-only change after the approval is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
cp "$tmp/app.good" app.py; rm other.py
expect_spy fail "a deleted module after the approval is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
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
expect_spy fail "a partial diff that omits another current module is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
# a failing model binary: production rejects it, the launcher exits non-zero and the model event keeps what the binary printed.
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
FAKE_CLAUDE_MODE=fail bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "a failed model run fails the launcher and its output stays in the model event" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); m=[e for e in es if e["wrapper"]=="model"][-1]; print(es[-1]["wrapper"]=="spy" and es[-1]["exit"]!=0 and m["exit"]==3 and "partial reply on stdout" in m["stdout"])' "$here" "$EVLOG")" = "True"

# cc11-main-r2 finding 1: a model call that exits nonzero after printing VERDICT: APPROVED is no verdict. The skills can only see what the
# reviewer launcher returns (its exit status and output), never the private model logs, so the launcher itself must exit non-zero.
# WHY this fails against an installed reviewer.sh whose run_sonnet swallows the model exit status (SPY_CONFIG_DIR=$HOME/.claude/config) and
# passes once the fixed reviewer.sh from the Global Config consolidated PR is the one installed (SPY_CONFIG_DIR=<that worktree>).
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
FAKE_CLAUDE_MODE=failapproved bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1; rc_failapproved=$?
expect_spy pass "a nonzero model call that printed VERDICT: APPROVED makes the reviewer launcher exit non-zero (no verdict)" test "$rc_failapproved" -ne 0
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "control: the same call with a zero exit and the same approval is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"

# cc11-main-r8: no skill, command or reference file calls an outside reviewer; a re-added call, a content scan or a fallback that skips tier S is caught by test-mirrors.py.
rm -rf "$tmp/mir8"; mkdir -p "$tmp/mir8"; cp -R "$here/../skills" "$here/../commands" "$here/../README.md" "$tmp/mir8/"
printf '\nRun `REVIEW_BASE_SHA=x ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>` first.\n' >> "$tmp/mir8/commands/claude-codex.md"
expect fail "an outside-reviewer call injected into a command is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"
cp "$here/../commands/claude-codex.md" "$tmp/mir8/commands/claude-codex.md"; printf '\nThen ask the gemini CLI to review.\n' >> "$tmp/mir8/commands/claude-codex.md"
expect fail "a Gemini instruction injected into a command is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"
cp "$here/../commands/claude-codex.md" "$tmp/mir8/commands/claude-codex.md"
expect pass "the pristine copy of the skills and commands passes the outside-reviewer rule" python3 "$here/test-mirrors.py" "$tmp/mir8"
# cc11-main-r9 finding 2: the tier S fallback must carry the Codex context (task requirements, instructions, carried and contested findings), not a bare diff.
mirc() { cp "$here/../commands/$1.md" "$tmp/mir8/commands/$1.md"; cp "$here/../skills/$1/SKILL.md" "$tmp/mir8/skills/$1/SKILL.md"; }
python3 - "$tmp/mir8/skills/tdd-claude-codex/SKILL.md" <<'PY'
import sys; p = sys.argv[1]; t = open(p).read()
open(p, "w").write(t.replace("reviewer.sh S <context-file> <out-file>", "reviewer.sh S <diff-file> <out-file>", 1))
PY
expect fail "a tier S fallback reverted to a bare diff file is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc tdd-claude-codex
python3 - "$tmp/mir8/skills/tdd-claude-codex/SKILL.md" "$tmp/mir8/commands/tdd-claude-codex.md" <<'PY'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); open(p, "w").write(t.replace("TASK REQUIREMENTS:", "NOTES:"))
PY
expect fail "a fallback input sequence without the task requirements section is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc tdd-claude-codex
python3 - "$tmp/mir8/commands/tdd-execute-codex.md" <<'PY'
import sys, re; p = sys.argv[1]; t = open(p).read()
open(p, "w").write(re.sub(r"\*\*Fallback input \(tier S\)\*\*:.*?\n```\n.*?\n```\n", "", t, flags=re.S))
PY
expect fail "a command that lost its Fallback input paragraph is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc tdd-execute-codex
python3 - "$tmp/mir8/skills/plan-codex/SKILL.md" "$tmp/mir8/commands/plan-codex.md" <<'PY'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); open(p, "w").write(t.replace("OPEN FINDINGS:", "OTHER:"))
PY
expect fail "a plan fallback sequence without the open findings section is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc plan-codex
python3 - "$tmp/mir8/skills/claude-codex/SKILL.md" "$tmp/mir8/commands/claude-codex.md" <<'PY'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); open(p, "w").write(t.replace(">> \"$CTX\"", "> \"$CTX\""))
PY
expect fail "a fallback sequence whose diff overwrites the context file instead of appending is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc claude-codex
python3 - "$tmp/mir8/skills/claude-codex/SKILL.md" "$tmp/mir8/commands/claude-codex.md" <<'PY'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); open(p, "w").write(t.replace(" | ~/.claude/config/scripts/redact-diff.sh >>", " >>"))
PY
expect fail "a fallback sequence that skips redact-diff.sh is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc claude-codex
# r11 finding 1: scripts/redact-diff.sh masks credential values in a diff (added AND deleted lines), keeps the diff structure, leaves a clean diff byte-identical.
red="$here/../scripts/redact-diff.sh"
fx="$tmp/secrets.diff"
{
  printf 'diff --git a/app.py b/app.py\nindex 111..222 100644\n--- a/app.py\n+++ b/app.py\n@@ -1,9 +1,9 @@ def main():\n'
  printf ' keep = "task-description-for-the-user-that-is-long"\n'
  for sign in - +; do
    printf '%s%s\n' "$sign" 'aws = "AKIAIOSFODNN7EXAMPLE"'
    printf '%s%s\n' "$sign" 'gh = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"'
    printf '%s%s\n' "$sign" 'pat = "github_pat_11ABCDEFG0123456789_abcdefghijklmnop"'
    printf '%s%s\n' "$sign" 'k = "sk-ant-api03-abcdefghijklmnopqrstuvwx"'
    printf '%s%s\n' "$sign" 'sl = "xoxb-123456789012-abcdefghijkl"'
    printf '%s%s\n' "$sign" 'h = {"Authorization": "Bearer abc123def456ghi789"}'
    printf '%s%s\n' "$sign" 'j = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop"'
    printf '%s%s\n' "$sign" 'password = "hunter2hunter2"'
    printf '%s%s\n' "$sign" 'API_KEY: zzTopSecretValue99'
    printf '%s%s\n' "$sign" '-----BEGIN RSA PRIVATE KEY-----'
    printf '%s%s\n' "$sign" 'MIIEowIBAAKCAQEAsupersecretkeybody'
    printf '%s%s\n' "$sign" '-----END RSA PRIVATE KEY-----'
  done
  printf ' tail = 1\n'
} > "$fx"
"$red" < "$fx" > "$tmp/secrets.out"
for v in AKIAIOSFODNN7EXAMPLE ghp_abcdefghij github_pat_11ABC sk-ant-api03 xoxb-1234 abc123def456ghi789 eyJhbGciOiJIUzI1NiJ9 hunter2hunter2 zzTopSecretValue99 MIIEowIBAAKCAQEAsupersecretkeybody; do
  expect fail "redact-diff leaves no trace of $v" grep -qF "$v" "$tmp/secrets.out"
done
expect pass "redact-diff keeps the hunk header, context lines and the +/- prefixes" test "$(grep -c '^@@ -1,9 +1,9 @@' "$tmp/secrets.out")$(grep -c '^ tail = 1$' "$tmp/secrets.out")$(grep -c '^-' "$tmp/secrets.out")$(grep -c '^+' "$tmp/secrets.out")" = "111313"
# r12 finding 2: escaped delimiters inside a quoted value must not end the value early.
rq() { printf '%s\n' "$1" | "$red"; }
expect fail "a double-quoted password with an escaped quote leaves no secret text" sh -c 'printf "%s\n" "+password = \"abSECRET\\\"cdTAIL\"" | "$1" | grep -q "SECRET\|TAIL"' _ "$red"
expect fail "a single-quoted password with an escaped quote leaves no secret text" sh -c "printf '%s\n' \"+token = 'abSECRET\\\\'cdTAIL'\" | \"\$1\" | grep -q 'SECRET\\|TAIL'" _ "$red"
expect fail "an unterminated quoted password masks to the end of the line" sh -c 'printf "%s\n" "+password = \"abSECRET and more TAIL" | "$1" | grep -q "SECRET\|TAIL"' _ "$red"
expect fail "a value ending in an escaped backslash leaves no secret text" sh -c 'printf "%s\n" "+password = \"abSECRET\\\\\"" | "$1" | grep -q "SECRET"' _ "$red"
expect pass "text after a value that ends in an escaped backslash is kept" sh -c 'printf "%s\n" "+password = \"abSECRET\\\\\", other = 1" | "$1" | grep -q "other = 1"' _ "$red"
# r13 finding 1: attack cases, one per shape the header comment claims. Each line is "input|||secret text that must not survive".
leaks() { printf '+%s\n' "$1" | "$red" | grep -qF -- "$2"; }
while IFS= read -r case_; do
  [ -n "$case_" ] || continue
  expect fail "redact-diff masks: ${case_%%|||*}" leaks "${case_%%|||*}" "${case_##*|||}"
done <<'ATTACKS'
Authorization: Bearer abcdefghijklmnop|||abcdefghijklmnop
Authorization: Bearer zq|||zq
"Authorization": "Bearer aB+c/d=="|||aB+c/d==
Authorization: Bearer a.b.c|||a.b.c
Authorization: Basic dXNlcjpwYXNz|||dXNlcjpwYXNz
Authorization: Token LEAKtok|||LEAKtok
headers = {'authorization': 'basic LEAKb64'}|||LEAKb64
token: Bearer abcdefghijklmnop|||abcdefghijklmnop
password=ab;cdLEAK|||cdLEAK
password: ab,cdLEAK|||cdLEAK
password=ab)cdLEAK|||cdLEAK
password = LEAKword|||LEAKword
password => "LEAKx"|||LEAKx
'password' => 'LEAKx'|||LEAKx
https://user:LEAKpw@host/path|||LEAKpw
postgres://u:LEAK%40pw@db:5432/x|||LEAK%40pw
export DB_PASSWORD=LEAKpw|||LEAKpw
export TOKEN="LEAK pw spaced"|||spaced
api_key: LEAKkey|||LEAKkey
x-api-key: LEAKkey|||LEAKkey
{"password":"LEAK\"x"}|||LEAK
{"password": LEAKnum}|||LEAKnum
ghp_abcd1234ef|||abcd1234ef
sk-LEAKabcdefg|||LEAKabcdefg
eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.|||eyJzdWIiOiJ4In0
xoxs-12345-LEAKabc|||LEAKabc
passphrase: LEAKphrase|||LEAKphrase
private_key = LEAKk|||LEAKk
PASSWORD=LEAKpw|||LEAKpw
GET /x?password=LEAKpw&user=bob|||LEAKpw
github_pat_AbCdEfGhIjKl|||AbCdEfGhIjKl
AKIAABCDEFGHIJKLMNOP|||ABCDEFGHIJKLMNOP
ATTACKS
# placeholders and ordinary code stay byte-identical
while IFS= read -r case_; do
  [ -n "$case_" ] || continue
  expect pass "redact-diff leaves a placeholder alone: $case_" sh -c 'printf "+%s\n" "$2" | "$1" | grep -qxF -- "+$2"' _ "$red" "$case_"
done <<'PLACEHOLDERS'
Authorization: Bearer ${TOKEN}
Authorization: Bearer <token>
Authorization: Bearer $TOKEN
auth = "Bearer " + token
f"Bearer {token}"
password = $PASS
token = get_token()
secret = os.environ["X"]
https://user:${PASS}@host/x
password: <your-password>
the task-list and sk-learn notes
PLACEHOLDERS
expect pass "redact-diff keeps the line count of the diff" test "$(wc -l < "$fx")" = "$(wc -l < "$tmp/secrets.out")"
expect pass "redact-diff does not touch a word that merely contains sk-" sh -c 'printf "+x = task-description-for-the-user-that-is-long\n" | "$1" | grep -q "task-description-for-the-user-that-is-long"' _ "$red"
printf 'diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1,2 +1,2 @@\n keep one\n-old line\n+new line\n' > "$tmp/clean.diff"
printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-hello world\n+hello there, a task-list and ask-me\n' >> "$tmp/clean.diff"
"$red" < "$tmp/clean.diff" > "$tmp/clean.out"
expect pass "a clean diff comes out byte-identical" cmp -s "$tmp/clean.diff" "$tmp/clean.out"
# a fallback sequence run for real: with the script missing no context file survives and the reviewer is never called.
sendtry() { # $1 = redactor path; runs the claude-codex fallback lines with a stub reviewer that records its call
  python3 - "$here/../skills/claude-codex/SKILL.md" "$1" "$tmp/sendtry.sh" "$tmp/reviewer-called" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
b = re.search(r"\*\*Fallback input \(tier S\)\*\*:.*?\n```\n(.*?)\n```\n", t, re.S).group(1)
b = b.replace("~/.claude/config/scripts/redact-diff.sh", sys.argv[2]).replace("~/.claude/config/scripts/reviewer.sh S", "touch " + sys.argv[4] + " #")
b = b.replace("<out-file>", "x")
open(sys.argv[3], "w").write(b + "\n")
PY
  # self-contained throwaway repo (one committed file plus an uncommitted change), so the case needs no history of this repo and works in a shallow clone
  rm -rf "$tmp/sendrepo"; mkdir -p "$tmp/sendrepo"; ( cd "$tmp/sendrepo" && git init -q && printf 'one\n' > f.txt && git add f.txt && git -c user.name=t -c user.email=t@t commit -q -m "$(printf 'base\n\nVerified: fixture repo for the fallback sequence')" && printf 'two\n' >> f.txt )
  rm -f "$tmp/reviewer-called"; ( cd "$tmp/sendrepo" && bash "$tmp/sendtry.sh" >/dev/null 2>&1 ); [ -f "$tmp/reviewer-called" ]
}
expect pass "the fallback sequence reaches the reviewer when the redaction script works" sendtry "$red"
expect fail "the fallback sequence never reaches the reviewer when the redaction script is missing" sendtry "$tmp/no-such-redactor.sh"
printf '#!/bin/sh\ncat; exit 3\n' > "$tmp/bad-redactor.sh"; chmod +x "$tmp/bad-redactor.sh"
expect fail "the fallback sequence never reaches the reviewer when the redaction script exits non-zero" sendtry "$tmp/bad-redactor.sh"
expect pass "the pristine copies pass the fallback-context rule" python3 "$here/test-mirrors.py" "$tmp/mir8"
# r10 finding 1: a delivery exit needs `VERDICT: APPROVED` AND zero findings; a bare BLOCKED or WARNING (no finding listed) is neither clean nor actionable.
isclean() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; sys.exit(0 if wlog.is_clean({"wrapper":"real","exit":0,"stdout":sys.argv[2].replace("\\n", "\n"),"stderr":""}) else 1)' "$here" "$1"; }
expect fail "a bare VERDICT: BLOCKED with no finding is not clean" isclean 'THREAD_ID: t\nVERDICT: BLOCKED\n'
expect fail "a bare VERDICT: WARNING with no finding is not clean" isclean 'THREAD_ID: t\nVERDICT: WARNING\n'
expect fail "VERDICT: APPROVED beside a real finding is not clean" isclean 'THREAD_ID: t\nVERDICT: APPROVED\nLOW: rename x\n'
expect pass "VERDICT: APPROVED with no finding is the only clean reply" isclean 'THREAD_ID: t\nVERDICT: APPROVED\n'
expect pass "grammar: a bare WARNING with no finding is findings (never clean)" test "$(gstate $'VERDICT: WARNING\n')" = findings
# WHY revert by regex over the exit line only: each injection puts back the pre-r10 wording ("a round that lists no findings") in ONE file, which the exit-line scan must catch.
revert_exit() { python3 - "$1" <<'PYX'
import re, sys
p = sys.argv[1]; t = open(p).read()
t2, n = re.subn(r"^(- \*\*Done\*\* → a round whose reply is exactly|- Exactly `VERDICT: APPROVED`|- A round whose reply is exactly)[^\n]*$", "- **Done** → a round that lists no findings. Only then go to Phase 3.", t, count=1, flags=re.M)
assert n == 1, p
open(p, "w").write(t2)
PYX
}
for cs in "plan-codex:skills/plan-codex/SKILL.md" "execute-codex:commands/execute-codex.md" "tdd-claude-codex:commands/tdd-claude-codex.md" "tdd-execute-codex:skills/tdd-execute-codex/SKILL.md" "claude-codex:skills/claude-codex/SKILL.md" "plan-codex:commands/plan-codex.md"; do
  revert_exit "$tmp/mir8/${cs#*:}"
  expect fail "a delivery exit reverted to bare 'no findings' in ${cs#*:} is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc "${cs%%:*}"
done
python3 - "$tmp/mir8/skills/codex-mcp/reference.md" <<'PYX'
import sys
p = sys.argv[1]; t = open(p).read(); open(p, "w").write(t.replace("replies exactly `VERDICT: APPROVED` with zero findings at any severity", "lists no accepted findings at any severity"))
PYX
expect fail "a codex-mcp loop exit that no longer requires APPROVED with zero findings is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; cp "$here/../skills/codex-mcp/reference.md" "$tmp/mir8/skills/codex-mcp/reference.md"
# r10 finding 2: the review record paragraph is mirrored and enforced
python3 - "$tmp/mir8/commands/execute-codex.md" <<'PYX'
import sys
p = sys.argv[1]; t = open(p).read(); i = t.index("**Review record (every reviewer round)**"); j = t.index("### Route A: Small"); open(p, "w").write(t[:i] + t[j:])
PYX
expect fail "a command that lost its Review record paragraph is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc execute-codex
python3 - "$tmp/mir8/skills/tdd-execute-codex/SKILL.md" <<'PYX'
import sys, re
p = sys.argv[1]; t = open(p).read()
t2 = re.sub(r"(H=\"\$\(set -o pipefail; git diff \$START_SHA) -- [^|]*\|", r"\1 |", t, count=1); assert t2 != t
open(p, "w").write(t2)
PYX
expect fail "a Review record hash taken over a diff without the secret excludes is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc tdd-execute-codex
python3 - "$tmp/mir8/skills/execute-codex/SKILL.md" "$tmp/mir8/commands/execute-codex.md" <<'PYX'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); t2 = t.replace(" ':(top,exclude).claude/review'", ""); assert t2 != t
    open(p, "w").write(t2)
PYX
expect fail "a Review record hash that does not exclude the .claude/review directory is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc execute-codex
python3 - "$tmp/mir8/skills/execute-codex/SKILL.md" "$tmp/mir8/commands/execute-codex.md" <<'PYX'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); t2 = t.replace("""printf 'REVIEWED-DIFF: %s\\n' "$H\"""", """printf 'REVIEWED-DIFF: %s\\n' "$(git diff HEAD | shasum -a 256)\""""); assert t2 != t
    open(p, "w").write(t2)
PYX
expect fail "a Review record hash computed inside the redirect (not into H first) is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc execute-codex
python3 - "$tmp/mir8/commands/tdd-execute-codex.md" <<'PYX'
import sys
p = sys.argv[1]; t = open(p).read(); open(p, "w").write(t.replace("} > .claude/review/final-review.txt", "} > /dev/null", 1))
PYX
expect fail "a Review record that no longer writes the record file is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc tdd-execute-codex
# r13 finding 2: the hash is taken and the exact diff snapshotted BEFORE the reviewer is dispatched, and compared with the tree after the reply
python3 - "$tmp/mir8/skills/execute-codex/SKILL.md" "$tmp/mir8/commands/execute-codex.md" <<'PYX'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); t2 = t.replace("""H="$(shasum -a 256 < .claude/review/reviewed.diff | cut -d' ' -f1)\"""", """H="$(git diff HEAD | shasum -a 256 | cut -d' ' -f1)\""""); assert t2 != t
    open(p, "w").write(t2)
PYX
expect fail "a Review record whose hash is moved back to after the reviewer call is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc execute-codex
python3 - "$tmp/mir8/skills/tdd-execute-codex/SKILL.md" "$tmp/mir8/commands/tdd-execute-codex.md" <<'PYX'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); t2 = t.replace(" | tee .claude/review/reviewed.diff", "", 1); assert t2 != t
    open(p, "w").write(t2)
PYX
expect fail "a Review record that no longer snapshots the reviewed diff before dispatch is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc tdd-execute-codex
python3 - "$tmp/mir8/skills/execute-codex/SKILL.md" "$tmp/mir8/commands/execute-codex.md" <<'PYX'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); t2 = t.replace("""= "$H" ]""", """= "" ]"""); assert t2 != t
    open(p, "w").write(t2)
PYX
expect fail "a Review record that no longer compares the tree after the reply with the pre-dispatch hash is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc execute-codex
# r14 finding 1: both steps check the diff pipeline status and reject an empty snapshot
python3 - "$tmp/mir8/skills/execute-codex/SKILL.md" "$tmp/mir8/commands/execute-codex.md" <<'PYX'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); t2 = t.replace("""N="$(set -o pipefail; git diff""", """N="$(git diff"""); assert t2 != t
    open(p, "w").write(t2)
PYX
expect fail "a Review record step 2 that no longer checks the diff pipeline status is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc execute-codex
python3 - "$tmp/mir8/skills/tdd-execute-codex/SKILL.md" "$tmp/mir8/commands/tdd-execute-codex.md" <<'PYX'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); t2 = t.replace("""H="$(set -o pipefail; git diff""", """H="$(git diff"""); assert t2 != t
    open(p, "w").write(t2)
PYX
expect fail "a Review record step 1 that no longer checks the diff pipeline status is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc tdd-execute-codex
python3 - "$tmp/mir8/skills/execute-codex/SKILL.md" "$tmp/mir8/commands/execute-codex.md" <<'PYX'
import sys
for p in sys.argv[1:]:
    t = open(p).read(); t2 = t.replace(""" && [ -s .claude/review/reviewed.diff ] && [ "$N\"""", """ && [ "$N\""""); assert t2 != t
    open(p, "w").write(t2)
PYX
expect fail "a Review record step 2 that accepts an empty snapshot is caught" python3 "$here/test-mirrors.py" "$tmp/mir8"; mirc execute-codex
expect pass "the pristine copies pass every r10 rule" python3 "$here/test-mirrors.py" "$tmp/mir8"

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
# cc11-main-r5 finding 2: the README must name the position the contract line really has (line 1 is the shebang).
expect pass "the README places the codex-call.sh contract line on the line it really is on" test "$(sed -n 2p "$here/../scripts/codex-call.sh" | cut -c1-22)" = "# contract: codex-call" -a -n "$(grep -F 'The second line of `scripts/codex-call.sh` is a contract line' "$here/../README.md")"

# CodeRabbit thread 7 (evlog.py:28): a marked plan that quotes a function signature is still a plan, not the implementation.
expect pass "a marked plan containing def add(a, b) is classified as a plan" test "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import evlog; print(evlog.phase_of("# Implementation plan\n\nAdd:\n    def add(a, b):\n        return a + b\n"))' "$here")" = "plan"
expect pass "a diff of an implementation file that contains def add is still the implementation" test "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import evlog; print(evlog.phase_of("diff --git a/app.py b/app.py\n+def add(a, b):\n"))' "$here")" = "implementation"
expect pass "unmarked text with def add(a, b) stays the implementation" test "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import evlog; print(evlog.phase_of("def add(a, b):\n    return a + b\n"))' "$here")" = "implementation"

# r17: the reviewed diff must match the remaining change exactly (whitespace, operators, the file set).
rv() { mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; }
rv; printf 'def add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a + b\n' > other.py
gdiff app.py other.py > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "an exact git diff of every changed module is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n    return a + b\n' > app.py; printf 'def sub(a, b):\n    return a + b\n' > other.py
gdiff app.py > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect_spy fail "a diff omitting a module whose lines duplicate reviewed ones is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n        return a + b\n' > app.py
gdiff app.py | sed 's/^+        return/+    return/' > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect_spy fail "a diff line with different indentation than the final code is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n    return a + b\n-x\n' > app.py
gdiff app.py | sed 's/^+-x$/+x/' > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect_spy fail "a source operator dropped from a diff line is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
rv; printf 'def add(a, b):\n    return a + b\n-x\n' > app.py
gdiff app.py > "$tmp/diff.txt"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "a line that starts with an operator is accepted when it is diffed exactly" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
# a spy whose output file cannot be written logs the shell diagnostic, not reviewer text the caller never saw.
rv; printf 'plan\n' > "$tmp/plan.md"
bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/nodir/out.txt" >/dev/null 2>"$tmp/spyerr.txt"
expect_spy pass "an unwritable output file logs production's outage message" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[-1]; print(e["exit"]!=0 and "UNAVAILABLE" in e["stderr"] and "VERDICT" not in e["stderr"])' "$here" "$EVLOG")" = "True"

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
expect_spy fail "a diff omitting a nested module is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
gdiff app.py pkg/mod.py > "$tmp/diff.txt"; : > "$EVLOG"; line fake 1 unknown "$LIMIT"
bash "$here/spy-reviewer.sh" S "$tmp/diff.txt" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "a complete diff including a nested module is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
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
expect_spy pass "the model really wrote stderr noise" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(any("noise from the model" in e["stderr"] for e in wlog.load(sys.argv[2]) if e["wrapper"]=="model"))' "$here" "$EVLOG")" = "True"
expect_spy pass "a successful spy call logs no stderr it never replayed" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=[x for x in wlog.load(sys.argv[2]) if x["wrapper"]=="spy"][-1]; print(e["exit"]==0 and e["stderr"]=="")' "$here" "$EVLOG")" = "True"
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
  expect_spy pass "the reply appears once on stdout for output path $op" test "$(printf '%s\n' "$got" | grep -c '^VERDICT')" = 1
  expect_spy pass "one event with one reply for $op" test "$(evone)" = True
done
mkrun; cd "$tmp/run/repo"; rm -f "$tmp/o.txt"
got="$(spyrun "$tmp/o.txt" 2>/dev/null)"
expect_spy pass "a file output path gets the reply once and stdout stays empty" test "$(grep -c '^VERDICT' "$tmp/o.txt"):${#got}" = "1:0"
expect_spy pass "one event with one reply for a file path" test "$(evone)" = True
mkrun; cd "$tmp/run/repo"
spyrun /dev/stderr >"$tmp/so.txt" 2>"$tmp/e.txt"; rc=$?
# WHY (r39): production reviewer.sh runs `run_sonnet 2>/dev/null` and does not accept /dev/stderr as an output file, so the real call delivers nothing.
expect_spy pass "production delivers no reply to /dev/stderr and the launcher fails like it" test "$rc:$(cat "$tmp/so.txt" "$tmp/e.txt" | grep -c '^VERDICT')" != "0:1"
expect_spy pass "and the event logs no verdict for /dev/stderr" test "$(evalias)" = True
# r31 (/dev/fd/3 3>&1), r32 (/dev/fd/5 and /dev/fd/6) and r33 (/dev/fd/0 0>&1): one delivery, one log entry each.
mkrun; cd "$tmp/run/repo"
got3="$(spyrun /dev/fd/3 3>&1 2>/dev/null)"
expect_spy pass "r31: /dev/fd/3 as a dup of stdout delivers once" test "$(printf '%s\n' "$got3" | grep -c '^VERDICT')" = 1
# WHY 0 (r40): a pipe behind an alias cannot be read without consuming it, so no reply is logged and the checker fails closed.
expect_spy pass "r31: the unobservable pipe delivery is not logged as a reply" test "$(evcount)" = 0
for n in 5 6; do
  mkrun; cd "$tmp/run/repo"; rm -f "$tmp/fd$n.txt"
  eval "spyrun /dev/fd/$n $n>\"$tmp/fd$n.txt\" >/dev/null 2>/dev/null"
  expect_spy pass "r32: /dev/fd/$n lands once in the file behind that descriptor" test "$(grep -c '^VERDICT' "$tmp/fd$n.txt")" = 1
  # WHY 0 (r40): production reads the output back and macOS denies reading /dev/fd/N behind a write-only descriptor, so reviewer.sh itself exits 1; the log must not claim a clean review.
  expect_spy pass "r32: production fails on the fd $n alias and no reply is logged" test "$(evcount)" = 0
done
mkrun; cd "$tmp/run/repo"
got0="$(spyrun /dev/fd/0 0>&1 2>/dev/null)"
expect_spy pass "r33: /dev/fd/0 with 0>&1 delivers once" test "$(printf '%s\n' "$got0" | grep -c '^VERDICT')" = 1
expect_spy pass "r33: the unobservable pipe delivery is not logged as a reply" test "$(evcount)" = 0

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
expect_spy pass "a reviewed patch that reproduces the final file is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
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
expect_spy fail "a stale patch with the same added line at another location is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"

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
expect_spy fail "a copy-only section that writes outside the sandbox is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
test ! -e "$tmp/run/escape.py"; expect_spy pass "the escaping copy target was never created" test ! -e "$tmp/run/escape.py"
mkrun; cd "$tmp/run/repo"; printf 'k\r\ndef add(a, b):\r\n    return a + b\r\n' > app.py; commitbase
printf 'k\r\nNEW\r\ndef add(a, b):\r\n    return a + b\r\n' > app.py
git diff --no-color HEAD -- app.py > "$tmp/crlf.diff"
limit_then_spy "$tmp/crlf.diff"
expect_spy pass "a correctly reviewed CRLF file is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
mkrun; bash "$here/spy-reviewer.sh" S "$tmp/plan.md" /dev/stderr >"$tmp/so.txt" 2>"$tmp/se.txt"
expect_spy pass "a reply to /dev/stderr never reaches the caller twice" test "$(cat "$tmp/so.txt" "$tmp/se.txt" | grep -c '^VERDICT')" -le 1
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
expect_spy pass "an implementation formatted as def add (a, b): return (a + b) is phase implementation" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["phase"])' "$here" "$EVLOG")" = implementation
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
expect_spy pass "a valid review beside an unchanged empty baseline file is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
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
expect_spy fail "a review sent to /dev/stderr (lost in production) does not count as clean" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
expect fail "a report whose last non-blank line is a closing fence after the status is rejected" st $'```\nAUDIT-STATUS: APPROVED reviewer=codex\n```'

# r24: structural phase, no-stop clause mirrored, shim subcommand parsing, git add -N never adds every untracked file
mkrun; cd "$tmp/run/repo"
printf 'add = lambda a, b: a + b\n' > "$tmp/lam.py"; git diff --no-index --no-color /dev/null "$tmp/lam.py" > "$tmp/lam.diff"
bash "$here/spy-reviewer.sh" S "$tmp/lam.diff" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "a lambda implementation is phase implementation" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["phase"])' "$here" "$EVLOG")" = implementation
mkdir -p "$tmp/tt"; printf 'def test_x():\n    def helper(a, b):\n        return a + b\n    assert helper(1, 2) == 3\n' > "$tmp/tt/test_app.py"; git diff --no-index --no-color /dev/null "$tmp/tt/test_app.py" > "$tmp/tt.diff"
mkrun; cd "$tmp/run/repo"; bash "$here/spy-reviewer.sh" S "$tmp/tt.diff" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "a tests-only diff containing return a + b is phase tests" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["phase"])' "$here" "$EVLOG")" = tests
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
expect_spy pass "a correctly reviewed zero-context patch is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --repo "$tmp/run/repo"
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
a="a Codex usage limit is never a blocker while tier S can run"; assert a in s
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
# Round 3 finding 1: the review contract omits empty severity lines, so a bare Codex approval IS a valid (and clean) verdict.
mkrun; line real 0 implementation 'THREAD_ID: abcdef12-3456\nVERDICT: APPROVED\n'
expect pass "a real Codex approval with no severity lines is a valid verdict" python3 "$here/check-real-basic.py" "$EVLOG" verdict
mkrun; line real 0 implementation 'THREAD_ID: abcdef12-3456\nVERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nLOW: none\n'
expect pass "a real Codex approval with only some placeholder severity lines is a valid verdict" python3 "$here/check-real-basic.py" "$EVLOG" verdict
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
expect pass "a real resume whose approval is the bare verdict line counts" python3 "$here/check-resume.py" "$EVLOG" --real

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
expect_spy pass "the spy refuses the diagnose tier" test "$src" -ne 0
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
expect_spy pass "production accepts tier R with a base and the CodeRabbit fake ran on committed state" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); m=[e for e in es if e["wrapper"]=="model"][-1]; print(m["meta"]["bin"], m["meta"]["tier"], m["meta"]["dirty"], m["meta"]["base"]==sys.argv[3])' "$here" "$EVLOG" "$R0")" = "coderabbit R 0 True"
orderfake "$EVLOG"
expect_spy pass "a clean tier R review of committed state is accepted for the code" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
expect_spy fail "a tier R review never validates a plan file" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/rin.txt"
printf 'x=1\ndef add(a, b):\n    return a - b\n' > app.py
expect_spy fail "code edited after the R review is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
rrun; printf 'x=1\ndef add(a, b):\n    return a - b\n' > app.py
REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "production lets tier R review while uncommitted changes exist (the fake records dirty=1)" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); print([e for e in es if e["wrapper"]=="model"][-1]["meta"]["dirty"])' "$here" "$EVLOG")" = 1
orderfake "$EVLOG"
expect_spy fail "a tier R review with uncommitted changes is rejected by the checker" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
rrun; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1
orderfake "$EVLOG"
expect_spy pass "a committed R review is accepted before a new file appears" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
printf 'def sneaky():\n    return 1\n' > "$tmp/run/repo/new_untracked.py"
expect_spy fail "an untracked .py file no commit holds is rejected (r39)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
rm -f "$tmp/run/repo/new_untracked.py"
rrun; printf 'def sneaky():\n    return 1\n' > "$tmp/run/repo/new_untracked.py"; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1
expect_spy pass "the CodeRabbit fake records an untracked .py as dirty" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print([e for e in wlog.load(sys.argv[2]) if e["wrapper"]=="model"][-1]["meta"]["dirty"])' "$here" "$EVLOG")" = 1
orderfake "$EVLOG"
expect_spy fail "an untracked .py present at review time is rejected by the checker (r39)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
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
expect_spy fail "a claude call carrying --version is not accepted as a review (r41)" python3 "$here/check-reviewer-after-limit.py" "$tmp/evV.jsonl" --plan-file "$tmp/plan.md"
expect_spy pass "the unmodified claude review is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
mkrun; cd "$tmp/run/repo"; out="$(PATH="$here/fake-models:$PATH" claude --version "x" 2>&1)"; rc=$?
expect pass "the fake claude refuses a --version call" test "$rc" != 0
rrun; printf 'x = 1\r\ny = 2\r\n' > "$tmp/run/repo/crlf.py"; commit2
REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"
expect_spy pass "a committed CRLF diff is accepted (r41)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
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
expect_spy fail "a CodeRabbit run of -t uncommitted does not validate committed code (r40)" python3 "$here/check-reviewer-after-limit.py" "$tmp/evU.jsonl" --repo "$tmp/run/repo"
rrun; printf 'node_modules\nsecret_mod.py\n' > "$tmp/run/repo/.gitignore"; printf 'def hidden():\n    return 2\n' > "$tmp/run/repo/secret_mod.py"
REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"
expect_spy fail "an ignored untracked .py module present at review time is rejected (r40)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
rrun; bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect_spy pass "production rejects tier R without REVIEW_BASE_SHA (exit 2, no clean review)" test "$rc" = 2
orderfake "$EVLOG"
expect_spy fail "and the checker finds no clean fallback review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG"
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan line one\nplan line two\n' > "$tmp/plan.md"
bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1
orderfake "$EVLOG"
expect_spy pass "a tier S plan review with the full file in the model prompt is accepted" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
expect_spy fail "a model prompt missing part of the plan is rejected" python3 "$here/check-reviewer-after-limit.py" "$EVLOG.trunc" --plan-file "$tmp/plan.md"
# cc11-main-r9 finding 2: with --context the reviewed input is the prescribed context file (headings first in order, the plan or diff last).
ctxrun() { mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; bash "$here/spy-reviewer.sh" S "$1" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"; }
printf 'the plan\n' > "$tmp/plan.md"
printf 'AUDIT INSTRUCTIONS:\naudit it\n\nOPEN FINDINGS:\nnone\n\nPLAN:\nthe plan\n' > "$tmp/ctxplan.txt"; ctxrun "$tmp/ctxplan.txt"
expect_spy pass "a plan context file (instructions, findings, then the plan) satisfies the plan review with --context" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md" --context
ctxrun "$tmp/plan.md"
expect_spy fail "a bare plan file no longer satisfies the plan review with --context" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md" --context
expect_spy pass "a bare plan file still satisfies the plan review without --context" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
printf 'AUDIT INSTRUCTIONS:\naudit it\n\nOPEN FINDINGS:\nnone\n\nPLAN:\nthe plan\nand then a trailing section\n' > "$tmp/ctxplan2.txt"; ctxrun "$tmp/ctxplan2.txt"
expect_spy fail "a plan context file whose plan is not the last section is rejected with --context" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md" --context
DIFFTXT='diff --git a/app.py b/app.py\n--- a/app.py\n+++ b/app.py\n@@ -1 +1,2 @@\n x=1\n+def add(a, b):\n'
printf "TASK REQUIREMENTS:\nAdd add(a, b) returning a + b.\n\nREVIEW INSTRUCTIONS:\nReview the diff.\n\nOPEN FINDINGS:\nnone\n\nDIFF:\n$DIFFTXT" > "$tmp/ctxcode.txt"; ctxrun "$tmp/ctxcode.txt"
expect_spy pass "a code context file with requirements, instructions, findings and the diff satisfies --context" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --context
printf "DIFF:\n$DIFFTXT" > "$tmp/ctxbare.txt"; ctxrun "$tmp/ctxbare.txt"
expect_spy fail "a code fallback input that is only a diff fails --context (the task requirements are missing)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --context
printf "TASK REQUIREMENTS:\n<the sanitized task requirements>\n\nREVIEW INSTRUCTIONS:\nReview.\n\nOPEN FINDINGS:\nnone\n\nDIFF:\n$DIFFTXT" > "$tmp/ctxtpl.txt"; ctxrun "$tmp/ctxtpl.txt"
expect_spy fail "a code context file whose requirements are still the template placeholder fails --context" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --phase implementation --context
# FIFO evidence (r37): the launcher opens the caller's output path once, so a one-shot reader gets the reply and nothing hangs.
mkrun; cd "$tmp/run/repo"; rm -f "$tmp/ff"; mkfifo "$tmp/ff"; printf 'plan\n' > "$tmp/plan.md"
( tmo 20 cat "$tmp/ff" > "$tmp/ff.out" ) & rd=$!
tmo 60 bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/ff" >/dev/null 2>&1; frc=$?; wait $rd
expect_spy pass "r37 FIFO: the launcher finishes against a one-shot FIFO reader which gets the reply exactly once" test "$frc:$(grep -c '^VERDICT' "$tmp/ff.out")" = "0:1"
expect_spy pass "and the unobservable FIFO delivery is not logged as a reply" test "$(evcount)" = 0
# fidelity link: a change to PRODUCTION reviewer.sh validation changes what the suite sees, with the launcher untouched.
# WHY a helper script that honors SPY_CONFIG_DIR (cc11-main-r1): the copy used to read from $HOME, so an otherwise valid override still needed the real installed config.
bash "$here/copy-config.sh" "$tmp/cfg"
expect_spy pass "the production-mutation copy honors SPY_CONFIG_DIR and never reads HOME" env HOME="$tmp/no-home" SPY_CONFIG_DIR="${SPY_CONFIG_DIR:-$HOME/.claude/config}" bash "$here/copy-config.sh" "$tmp/cfg-home-test"
sed -i.bak 's/^  E|R|S|diagnose) ;;$/  E|R|diagnose) ;;/' "$tmp/cfg/scripts/reviewer.sh"
mkrun; line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
SPY_CONFIG_DIR="$tmp/cfg" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect_spy pass "with production validation changed to reject tier S the unchanged launcher fails" test "$rc" = 1
orderfake "$EVLOG"
expect_spy fail "and the checker sees no clean fallback review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"

# r34: an unwritable output path delivers nothing and the event must not log the reply
mkrun; cd "$tmp/run/repo"
spyrun "$tmp/no-such-dir/o.txt" >/dev/null 2>&1; rc=$?
expect_spy pass "an unwritable output path fails the spy" test "$rc" != 0
expect_spy pass "and the event stderr holds the outage message once" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; e=wlog.load(sys.argv[2])[-1]; print(e["stderr"].count("UNAVAILABLE"))' "$here" "$EVLOG")" = 1
expect_spy pass "and the event logs no reply" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); print(len([x for x in es if x["wrapper"]=="spy"])==1 and "VERDICT" not in wlog.reply_text(es[-1]))' "$here" "$EVLOG")" = True

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
expect_spy pass "the spy completes against a named FIFO reader" test "$frc" = 0
expect_spy pass "and the reader got the reply once" test "$(grep -c '^VERDICT' "$tmp/ff.got")" = 1

# r42 (CodeRabbit): check-impl needs proof the asserts ran, a rename counts its new path, and each wrapper has one clean form
printf 'import os\nos._exit(0)\n' > "$tmp/exit0.py"; printf 'def add(a, b):\n    return a + b\n' > "$tmp/good.py"
expect fail "a module that exits 0 on import is not a passing implementation" python3 "$here/check-impl.py" "$tmp/exit0.py"
expect pass "a real add passes check-impl" python3 "$here/check-impl.py" "$tmp/good.py"
expect pass "a rename from test_app.py to app.py is the implementation phase" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import evlog; print(evlog.phase_of("diff --git a/test_app.py b/app.py\nsimilarity index 90%\nrename from test_app.py\nrename to app.py\n"))' "$here")" = implementation
expect pass "placeholder severity lines are clean for a reviewer.sh spy reply too (one grammar)" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; sys.exit(0 if wlog.is_clean({"wrapper":"spy","exit":0,"stdout":"VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n","stderr":""}) else 1)' "$here"

mkdir -p "$tmp/em"; for m in mathops strops listops pkginfo; do printf 'import os\nos._exit(0)\n' > "$tmp/em/$m.py"; done
expect fail "four modules that exit 0 on import do not pass check-modules" python3 "$here/check-modules.py" "$tmp/em"

# cc11-main-r6 finding 2: the real scenario must verify the requested work, not only thread mechanics. check-behavior.sh is the one acceptance step review-loop-proof.sh calls
# from the real branch (and the scripted and usage-limit branches), so these cases drive it on work dirs a real run would leave behind, with no Codex quota spent.
bw="$tmp/bw"; mkdir -p "$bw/empty" "$bw/mods" "$bw/impl" "$bw/stub" "$bw/plan/.claude/plan" "$bw/noplan/.claude/plan"
cat > "$bw/mods/mathops.py" <<'PYM'
def add(a, b):
    """>>> add(1, 2)
    3
    """
    return a + b
def sub(a, b):
    """>>> sub(3, 1)
    2
    """
    return a - b
PYM
printf 'def shout(s):\n    """>>> shout("hi")\n    \x27HI!\x27\n    """\n    return s.upper() + "!"\n' > "$bw/mods/strops.py"
printf 'def first(xs):\n    """>>> first([7, 8])\n    7\n    """\n    return xs[0]\n' > "$bw/mods/listops.py"
printf 'VERSION = "1.0"\ndef describe():\n    """>>> describe()\n    \x27v1.0\x27\n    """\n    return "v" + VERSION\n' > "$bw/mods/pkginfo.py"
printf 'def add(a, b):\n    return a + b\n' > "$bw/impl/app.py"; printf 'def add(a, b):\n    return 0\n' > "$bw/stub/app.py"
printf 'Plan: add an add(a, b) function to app.py.\n' > "$bw/plan/.claude/plan/p.md"; : > "$bw/noplan/.claude/plan/p.md"
expect fail "real execute-codex run whose work dir lacks the four modules fails the acceptance step" bash "$here/check-behavior.sh" execute-codex "$bw/empty" real
expect pass "real execute-codex run with the four correct modules passes the acceptance step" bash "$here/check-behavior.sh" execute-codex "$bw/mods" real
expect fail "real claude-codex run with no app.py add fails the acceptance step" bash "$here/check-behavior.sh" claude-codex "$bw/empty" real
expect fail "real claude-codex run whose add is a stub fails the acceptance step" bash "$here/check-behavior.sh" claude-codex "$bw/stub" real
expect pass "real claude-codex run with a working add passes the acceptance step" bash "$here/check-behavior.sh" claude-codex "$bw/impl" real
for sk in tdd-claude-codex tdd-execute-codex codex-mcp; do
  expect fail "real $sk run with no add fails the acceptance step" bash "$here/check-behavior.sh" $sk "$bw/empty" real
  expect pass "real $sk run with a working add passes the acceptance step" bash "$here/check-behavior.sh" $sk "$bw/impl" real
done
expect fail "real plan-codex run with no plan file fails the acceptance step" bash "$here/check-behavior.sh" plan-codex "$bw/empty" real
expect fail "real plan-codex run with an empty plan file fails the acceptance step" bash "$here/check-behavior.sh" plan-codex "$bw/noplan" real
expect pass "real plan-codex run with a plan about the request passes the acceptance step" bash "$here/check-behavior.sh" plan-codex "$bw/plan" real
expect fail "an unknown skill never passes the acceptance step" bash "$here/check-behavior.sh" nonsense "$bw/impl" real
expect fail "execute-codex scripted scenarios still expect the small add, so four modules alone fail" bash "$here/check-behavior.sh" execute-codex "$bw/mods" round6
# the acceptance step runs inside every branch of the proof before that branch exits (a branch that exits first is the bug this case guards)
expect pass "every scenario branch of review-loop-proof.sh calls check-behavior.sh before its exit" python3 - "$here/review-loop-proof.sh" <<'PYB'
import re, sys
t = open(sys.argv[1]).read()
for name, start, end in (("real", 'if [[ $scenario == real ]]; then\n  NOVERDICT', "  exit $fail\nfi\nif [[ $scenario == usage-limit ]]"), ("usage-limit", "if [[ $scenario == usage-limit ]]; then\n  # Codex is over quota", "  exit $fail\nfi\ncheck \"every finding round")):
    i = t.index(start); j = t.index(end, i)
    if "check-behavior.sh" not in t[i:j]: sys.exit("%s branch never calls check-behavior.sh before exiting" % name)
tail = t[t.index('check "every finding round'):]
if "check-behavior.sh" not in tail.split("exit $fail")[0]: sys.exit("scripted branch never calls check-behavior.sh before exiting")
PYB

# r44: a clean review followed by a malformed review attempt is not approved
rrun; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1; orderfake "$EVLOG"
expect_spy pass "the clean tier R review is accepted before a malformed call" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
sleep 1; bash "$here/spy-reviewer.sh" Z "$tmp/rin.txt" "$tmp/out2.txt" >/dev/null 2>&1
expect_spy fail "a malformed review call after the clean one is the final event and is rejected (r44)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"
bash "$here/spy-reviewer.sh" diagnose "$tmp/rin.txt" "$tmp/out3.txt" >/dev/null 2>&1
expect_spy fail "a diagnose call does not rescue it" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"

# r45: production caches a tier R verdict by input hash, so a repeat after a new commit may return the old approval with no model run
rrun; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out.txt" >/dev/null 2>&1
printf 'x=1\ndef add(a, b):\n    return a + b\ndef sub(a, b):\n    return a - b\n' > "$tmp/run/repo/app.py"; commit2
sleep 1; REVIEW_BASE_SHA="$R0" bash "$here/spy-reviewer.sh" R "$tmp/rin.txt" "$tmp/out2.txt" >/dev/null 2>&1
expect_spy pass "the repeat review on unchanged input runs through the same private cache as production" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); sp=[e for e in es if e["wrapper"]=="spy"]; md=[e for e in es if e["wrapper"]=="model"]; print(len(sp), len(md))' "$here" "$EVLOG")" = "2 1"
orderfake "$EVLOG"
expect_spy fail "a cached approval with no model run behind it is rejected for the new commit (r45)" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --repo "$tmp/run/repo"

# r46: the launcher must behave like a direct production call for stream aliases (pipes stay pipes)
for op in /dev/stdout /dev/fd/1 /dev/stderr; do
  mkrun; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"; mkdir -p "$tmp/dh"
  # WHY the real config path is fixed first: in one assignment list `HOME=... CLAUDE_CONFIG_DIR=$HOME/...` would expand against the NEW HOME.
  cfg="${SPY_CONFIG_DIR:-$HOME/.claude/config}"
  d_out="$(HOME="$tmp/dh" CLAUDE_CONFIG_DIR="$cfg" PATH="$here/fake-models:$PATH" EVLOG="$tmp/direct.jsonl" bash "$cfg/scripts/reviewer.sh" S "$tmp/plan.md" "$op" 2>/dev/null)"; d_rc=$?
  s_out="$(spyrun "$op" 2>/dev/null)"; s_rc=$?
  expect_spy pass "direct production and the launcher agree on rc and stdout for $op (r46)" test "$d_rc:$d_out" = "$s_rc:$s_out"
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
expect_spy fail "a CodeRabbit review whose model-time tree digest differs from the launcher's is rejected (r47)" python3 "$here/check-reviewer-after-limit.py" "$tmp/evT.jsonl" --repo "$tmp/run/repo"
expect_spy pass "a model event keeps its place after the quota event once the quota is ordered" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; es=wlog.load(sys.argv[2]); q=[e for e in es if e["wrapper"]=="fake"][0]; print(all(e["ts"]>q["ts"] for e in es if e["wrapper"]=="model"))' "$here" "$EVLOG")" = True
expect_spy fail "the suite stops with a clear line when the installed reviewer.sh is missing" env SPY_CONFIG_DIR="$tmp/no-such-config" bash "$here/test-checkers.sh"

# cc11-main-r1: the portable timeout stand-in kills a slow command with 124 and passes through a fast command's status
expect pass "tmo python fallback kills a slow command with exit 124" test "$(TMO_FORCE_PY=1 tmo 1 sleep 5 >/dev/null 2>&1; echo $?)" = 124
expect pass "tmo python fallback passes through the command exit status" test "$(TMO_FORCE_PY=1 tmo 5 bash -c 'exit 3' >/dev/null 2>&1; echo $?)" = 3

# cc11-main-r1: tier S fallback must work in a repo with NO origin remote and for a scratch plan in a folder that is not a repo
# (scripts/codex-call.sh runs plan audits from scratch folders). The review-loop-proof fixture used to add an origin because an older
# reviewer.sh exited without one; the real reviewer.sh must now succeed, and so must the fixture, without it.
mkrun; (cd "$tmp/run/repo" && git remote remove origin); line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
spyrun "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect_spy pass "tier S fallback succeeds in a repo with no origin remote" test "$rc" = 0
orderfake "$EVLOG"
expect_spy pass "and the checker sees the clean fallback review" python3 "$here/check-reviewer-after-limit.py" "$EVLOG" --plan-file "$tmp/plan.md"
mkrun; line fake 1 unknown "$LIMIT"; rm -rf "$tmp/scratch"; mkdir -p "$tmp/scratch"; cd "$tmp/scratch"; printf 'plan\n' > "$tmp/plan.md"
spyrun "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect_spy pass "tier S fallback succeeds for a scratch plan outside any git repo" test "$rc" = 0
# mutation proof source: a reviewer.sh that exits when there is no origin (the old behavior) must make the first case fail
bash "$here/copy-config.sh" "$tmp/cfg-noorigin"
sed -i.bak 's|^_rq_slug=\$(git -C "\$REPO_ROOT" remote get-url origin.*$|git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>\&1 \|\| exit 9; _rq_slug=x|' "$tmp/cfg-noorigin/scripts/reviewer.sh"
mkrun; (cd "$tmp/run/repo" && git remote remove origin); line fake 1 unknown "$LIMIT"; cd "$tmp/run/repo"; printf 'plan\n' > "$tmp/plan.md"
SPY_CONFIG_DIR="$tmp/cfg-noorigin" bash "$here/spy-reviewer.sh" S "$tmp/plan.md" "$tmp/out.txt" >/dev/null 2>&1; rc=$?
expect_spy pass "control: an origin-requiring reviewer.sh makes the no-remote case fail (the test can detect the old bug)" test "$rc" = 9

# cc11-main-r8 change B + r9 finding 1: the real scenario binds the reported approval to the FINAL real reviewer result in the log, for the FINAL state and (tdd skills) the implementation phase (fabricated logs, no quota).
# The binding is check-scripted.py `final --real`, the same mechanism the scripted branch uses; the real shim records state and impl in each event's meta.
FIND='VERDICT: WARNING\nHIGH: a finding\n'; BLOCK='VERDICT: BLOCKED\nCRITICAL: a finding\n'; TID="THREAD_ID: 01a1d2dc-5af3-7192-9860-6e8ea8ed1425\n"
fr() { python3 "$here/check-scripted.py" "$EVLOG" final S1 --real "$@"; }
mkrun; LINEMETA="state=S1 endstate=S1 impl=yes" line real 0 review "$TID$BLOCK"
expect fail "a final BLOCKED review fails the final-result check even though the agent reports APPROVED" fr
mkrun; LINEMETA="state=S1 endstate=S1 impl=yes" line real 0 review "$TID$CLEAN"; LINEMETA="state=S1 endstate=S1 impl=yes" line real 1 review "codex-call: UNREVIEWED"
expect fail "a clean review followed by a later failed call fails the final-result check" fr
mkrun; LINEMETA="state=S1 endstate=S1 impl=yes" line real 0 review "$TID$CLEAN"; LINEMETA="state=S1 endstate=S1 impl=yes" line real 0 review "$TID$BLOCK"
expect fail "a clean review followed by a later BLOCKED review fails the final-result check" fr
mkrun; LINEMETA="state=S1 endstate=S1 impl=yes" line real 0 review "$TID$FIND"; LINEMETA="state=S1 endstate=S1 impl=yes" line real 0 review "$TID$CLEAN"
expect pass "findings then a clean last review on the final state passes the final-result check" fr
mkrun; LINEMETA="state=S1 endstate=S1 impl=yes" line real 0 review "${TID}VERDICT: APPROVED\nCRITICAL: a real finding\n"
expect fail "an APPROVED line that carries a real finding is not a clean final result" fr
mkrun
expect fail "an empty log has no final reviewer result" fr
mkrun; LINEMETA="state=S1 endstate=S1 impl=no" line real 0 review "$TID$CLEAN"
expect fail "tdd: a clean TEST AUDIT with no implementation review fails the final-result check" fr --impl
mkrun; LINEMETA="state=S1 endstate=S1 impl=no" line real 0 review "$TID$CLEAN"
expect pass "non-tdd skills are not held to the implementation phase (same log passes without --impl)" fr
mkrun; LINEMETA="state=S0 endstate=S0 impl=no" line real 0 review "$TID$CLEAN"
expect fail "tdd: a clean test audit followed by implementation edits (final state differs) fails the final-result check" fr --impl
mkrun; LINEMETA="state=S0 endstate=S0 impl=yes" line real 0 review "$TID$CLEAN"
expect fail "a clean implementation review followed by a later file change (final state differs) fails the final-result check" fr --impl
mkrun; LINEMETA="state=S0 endstate=S0 impl=yes" line real 0 review "$TID$CLEAN"
expect fail "non-tdd: a clean review followed by a later file change also fails (state binding applies to every skill)" fr
mkrun; LINEMETA="state=S0 endstate=S0 impl=no" line real 0 review "$TID$FIND"; LINEMETA="state=S1 endstate=S1 impl=yes" line real 0 review "$TID$CLEAN"
expect pass "tdd: a clean implementation review on the final state passes the final-result check" fr --impl
mkrun; line real 0 review "$TID$CLEAN"
expect fail "a clean real review that recorded no state at all is not bound to the final state" fr
expect pass "the real branch runs the bound final-result check once, with --impl for tdd-claude-codex only" sh -c "test \"\$(grep -c 'check-scripted.py\" \"\$out/wrapper.jsonl\" final \"\$real_final_state\" --real \$IMPLFLAG' '$here/review-loop-proof.sh')\" = 1 && grep -q 'IMPLFLAG=; \[\[ \$skill == tdd-claude-codex \]\] && IMPLFLAG=--impl' '$here/review-loop-proof.sh'"
# the shim records the repo state and the impl flag in the event meta, computed by the same state-hash.py and check-impl.py
mkrun; printf 'def add(a, b):\n    return a + b\n' > "$tmp/run/repo/app.py"
PROOF_REPO="$tmp/run/repo" REAL_CODEX="$tmp/realbin/codex" viawrap exec --json prompt >/dev/null 2>&1
expect pass "the shim records the final-state hash and impl=yes in the real event" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; m=wlog.load(sys.argv[2])[-1]["meta"]; print(m.get("state")+" "+m.get("impl"))' "$here" "$EVLOG")" = "$(python3 "$here/state-hash.py" "$tmp/run/repo") yes"
printf 'x=1\n' > "$tmp/run/repo/app.py"
PROOF_REPO="$tmp/run/repo" REAL_CODEX="$tmp/realbin/codex" viawrap exec --json prompt >/dev/null 2>&1
expect pass "the shim records impl=no when add() does not exist" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["meta"].get("impl"))' "$here" "$EVLOG")" = no
audmeta() { python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; print(wlog.load(sys.argv[2])[-1]["meta"].get("audit"))' "$here" "$EVLOG"; }
PROOF_REPO="$tmp/run/repo" REAL_CODEX="$tmp/realbin/codex" viawrap exec --json --sandbox read-only prompt >/dev/null 2>&1
expect pass "the shim marks a read-only call as an audit attempt at call time" test "$(audmeta)" = yes
PROOF_REPO="$tmp/run/repo" REAL_CODEX="$tmp/realbin/codex" viawrap exec --json --sandbox workspace-write prompt >/dev/null 2>&1
expect pass "the shim marks a workspace-write call as no audit at call time" test "$(audmeta)" = no

# r10 finding 2: tdd-execute-codex and execute-codex review with a Claude code-reviewer agent, not Codex. The real proof therefore (a) binds the LAST Codex
# test-audit verdict (tdd-execute-codex) and (b) validates the durable review record the skill prescribes: .claude/review/final-review.txt holds
# `REVIEWED-DIFF: <sha256 of the reviewed diff>` then the reviewer's verbatim reply.
# r13 finding 2: the reviewer must have judged the tree the run ended with. The shim records the state at call START (state) and at the verdict (endstate); a file edited while
# the reviewer runs makes them differ, and an approval for the earlier tree must not count for the current one.
mkrun; LINEMETA="state=S1 endstate=S2 impl=yes" line real 0 review "$TID$CLEAN"
expect fail "an approval whose tree changed while the reviewer ran (start state differs from the verdict state) fails" fr --impl
mkrun; LINEMETA="state=S0 endstate=S1 impl=yes" line real 0 review "$TID$CLEAN"
expect fail "an approval started on an older tree and ended on the final one still fails" fr --impl
mkrun; LINEMETA="state=S1 impl=yes" line real 0 review "$TID$CLEAN"
expect fail "an approval that recorded no verdict-time state fails" fr --impl
mkrun; LINEMETA="state=S1 endstate=S1 impl=yes" line real 0 review "$TID$CLEAN"
expect pass "an approval on an unchanged final tree passes" fr --impl
mkdir -p "$tmp/realbin2"; cat > "$tmp/realbin2/codex" <<'SH'
#!/usr/bin/env bash
sleep 0.3; printf 'def sub(a, b):\n    return a - b\n' >> "$PROOF_REPO/app.py"
echo '{"type":"thread.started","thread_id":"abcdef12-3456"}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none"}}'
echo '{"type":"turn.completed"}'; exit 0
SH
chmod +x "$tmp/realbin2/codex"
mkrun; printf 'def add(a, b):\n    return a + b\n' > "$tmp/run/repo/app.py"; start0="$(python3 "$here/state-hash.py" "$tmp/run/repo")"
PROOF_REPO="$tmp/run/repo" REAL_CODEX="$tmp/realbin2/codex" viawrap exec --json --sandbox read-only prompt >/dev/null 2>&1
expect pass "the shim records the state at call START and a different state at the verdict when a file is edited meanwhile" test "$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import wlog; m=wlog.load(sys.argv[2])[-1]["meta"]; print(m["state"]==sys.argv[3], m["endstate"]!=sys.argv[3])' "$here" "$EVLOG" "$start0")" = "True True"
expect fail "the real log of a file edited while the reviewer ran does not bind to the final tree" python3 "$here/check-scripted.py" "$EVLOG" final "$(python3 "$here/state-hash.py" "$tmp/run/repo")" --real
expect fail "the same log fails the audit binding too" python3 "$here/check-scripted.py" "$EVLOG" final X --real --audit
au() { python3 "$here/check-scripted.py" "$EVLOG" final X --real --audit; }
mkrun; expect fail "audit: no Codex verdict at all fails the test-audit check" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "${TID}VERDICT: BLOCKED\nHIGH: weak test\n"
expect fail "audit: a last Codex verdict of BLOCKED with a finding fails" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "${TID}VERDICT: BLOCKED\n"
expect fail "audit: a bare BLOCKED with no finding is not clean" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "${TID}VERDICT: WARNING\n"
expect fail "audit: a bare WARNING with no finding is not clean" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "${TID}VERDICT: APPROVED\nCRITICAL: a real finding\n"
expect fail "audit: APPROVED beside a finding is not clean" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "$TID$FIND"; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "$TID$CLEAN"
expect pass "audit: findings then a clean APPROVED with zero findings passes" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "$TID$CLEAN"; LINEMETA="state=S1 endstate=S1 impl=yes audit=no" line real 0 impl "${TID}Implemented add() in app.py.\n"
expect pass "audit: a later Codex implementation reply (no verdict) does not displace the clean audit" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "$TID$CLEAN"; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "$TID$BLOCK"
expect fail "audit: a clean audit followed by a later BLOCKED verdict fails" au
mkrun; LINEMETA="audit=yes" line real 0 review "$TID$CLEAN"
expect fail "audit: a clean verdict that recorded no state fails" au
# r11 finding 2: an audit ATTEMPT is told apart from an implementation call by the audit= marker the shim records at call time (the sandbox the call asked for),
# never by whether a verdict came back, so a failed or malformed re-audit cannot be filtered away before the latest one is chosen.
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "$TID$CLEAN"; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 1 review "codex-call: UNREVIEWED"
expect fail "audit: a clean audit followed by a failed re-audit fails" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "$TID$CLEAN"; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "${TID}no verdict here at all\n"
expect fail "audit: a clean audit followed by a malformed re-audit fails" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "$TID$CLEAN"; LINEMETA="state=S1 endstate=S1 impl=yes audit=no" line real 1 impl "codex-call: UNREVIEWED"
expect pass "audit: a clean audit followed by a failed implementation call still passes" au
mkrun; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 1 review "codex-call: UNREVIEWED"; LINEMETA="state=S0 endstate=S0 impl=no audit=yes" line real 0 review "$TID$CLEAN"
expect pass "audit: a failed audit followed by a clean re-audit passes" au
mkrun; LINEMETA="state=S0 endstate=S1 impl=no audit=yes" line real 0 review "$TID$CLEAN"
expect fail "audit: a clean audit whose tree changed while it ran fails" au
# the review record: built against a real tiny git repo, hashing the same diff command the skills prescribe
rr() { python3 "$here/check-review-record.py" "$tmp/rr" "$(git -C "$tmp/rr" rev-list --max-parents=0 HEAD)"; }
rrhash() { (cd "$tmp/rr" && git add -N app.py 2>/dev/null; git diff "$(git rev-list --max-parents=0 HEAD)" -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' ':(top,exclude).claude/review' | shasum -a 256 | cut -d' ' -f1); }
rrmk() { rm -rf "$tmp/rr"; mkdir -p "$tmp/rr"; (cd "$tmp/rr" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$(printf 's\n\nVerified: fixture repo for the review-record cases')" && printf 'def add(a, b):\n    return a + b\n' > app.py); }
rrrec() { mkdir -p "$tmp/rr/.claude/review"; printf 'REVIEWED-DIFF: %s\n%b' "$1" "$2" > "$tmp/rr/.claude/review/final-review.txt"; }
rrmk
# r13 finding 2: run the prescribed two-step sequence itself (extracted from the skill) against the fixture repo. The base is the root commit, so the command's HEAD base is swapped for it.
python3 - "$here/../skills/execute-codex/SKILL.md" "$tmp/step1.sh" "$tmp/step2.sh" <<'PYX'
import re, sys
t = open(sys.argv[1]).read(); i = t.index("**Review record (every reviewer round)**")
f = re.findall(r"```\n(.*?)\n```", t[i:], re.S)[:2]
open(sys.argv[2], "w").write(f[0] + "\n"); open(sys.argv[3], "w").write(f[1] + "\n")
PYX
rrstep() { (cd "$tmp/rr" && git add -N app.py && base="$(git rev-list --max-parents=0 HEAD)" && sed "s/git diff HEAD/git diff $base/g; s/<the reviewer's reply, verbatim>/VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none/" "$tmp/$1" | bash -e); }
rrmk; rrstep step1.sh; rrstep step2.sh
expect pass "the prescribed sequence on an unchanged tree writes a record the checker accepts" rr
rrmk; rrstep step1.sh; printf '\ndef sub(a, b):\n    return a - b\n' >> "$tmp/rr/app.py"; rrstep step2.sh
expect fail "the prescribed sequence voids the round when a file is edited while the reviewer ran (no record, nothing approved)" test -s "$tmp/rr/.claude/review/final-review.txt"
expect fail "an edit during the review leaves nothing the checker accepts" rr
rrmk; rrstep step1.sh; rrstep step2.sh; printf '\ndef sub(a, b):\n    return a - b\n' >> "$tmp/rr/app.py"
expect fail "an earlier round's record does not approve a later edit" rr
# r14 finding 1: a pipeline failure or an empty diff voids the round at step 1 AND at step 2, removes any old record and records nothing. rrstepx runs the extracted block with NO `set -e` (the block must handle
# its own failures) and, when FAILSUB is given, with a stub git whose subcommand FAILSUB exits 1.
rrstepx() { (cd "$tmp/rr" && { [ ! -e app.py ] || git add -N app.py; } && base="$(git rev-list --max-parents=0 HEAD)" && sed "s/git diff HEAD/git diff $base/g; s/<the reviewer's reply, verbatim>/VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none/" "$tmp/$1" > "$tmp/x-$1" && if [[ -n "${2:-}" ]]; then FAILSUB="$2" PATH="$tmp/stubgit:$PATH" bash "$tmp/x-$1"; else bash "$tmp/x-$1"; fi) >/dev/null 2>&1; }
rrstale() { rrrec "$(rrhash)" "VERDICT: APPROVED\n"; }
rrmk; rrstale; rrstepx step1.sh diff; rrstepx step2.sh
expect fail "a git diff that fails at step 1 leaves no record (the old record is removed and no snapshot is kept)" test -e "$tmp/rr/.claude/review/final-review.txt" -o -s "$tmp/rr/.claude/review/reviewed.diff"
rrmk; rrstepx step1.sh; rrstale; rrstepx step2.sh diff
expect fail "a git diff that fails at step 2 leaves no record (the old record is removed)" test -e "$tmp/rr/.claude/review/final-review.txt"
rrmk; rrstale; rrstepx step1.sh diff; rrstepx step2.sh diff
expect fail "a git diff that fails at both steps leaves no record, whatever hash empty input has" test -e "$tmp/rr/.claude/review/final-review.txt"
rrmk; rm -f "$tmp/rr/app.py"; rrstale 2>/dev/null; rrstepx step1.sh; rrstepx step2.sh
expect fail "an empty diff leaves no record and no snapshot" test -e "$tmp/rr/.claude/review/final-review.txt" -o -e "$tmp/rr/.claude/review/reviewed.diff"
rrmk; rrstepx step1.sh; rrstepx step2.sh
expect pass "the same block with a working git and a real diff still records" rr
# r14 finding 3: the whole .claude/review/ directory (record, snapshot, anything added later) is outside the hashed diff, so tracking any of it never turns an unchanged round stale
rrsnap() { mkdir -p "$tmp/rr/.claude/review"; printf 'snapshot\n' > "$tmp/rr/.claude/review/reviewed.diff"; printf 'other\n' > "$tmp/rr/.claude/review/notes.txt"; }
rrmk; H0="$(rrhash)"; rrsnap; (cd "$tmp/rr" && git add -f .claude/review/reviewed.diff); rrrec "$H0" "VERDICT: APPROVED\n"
expect pass "a tracked snapshot leaves an unchanged round's record valid" rr
rrmk; H0="$(rrhash)"; rrsnap; (cd "$tmp/rr" && git add -f -N .claude/review/reviewed.diff .claude/review/notes.txt); rrrec "$H0" "VERDICT: APPROVED\n"
expect pass "an intent-to-add snapshot and other file under .claude/review leave an unchanged round's record valid" rr
rrmk; H0="$(rrhash)"; rrsnap; rrrec "$H0" "VERDICT: APPROVED\n"; (cd "$tmp/rr" && git add -f .claude/review)
expect pass "the record and the snapshot both tracked leave an unchanged round's record valid" rr
printf '\ndef sub(a, b):\n    return a - b\n' >> "$tmp/rr/app.py"
expect fail "a real code change still makes the record stale with the review directory tracked" rr
expect fail "review record: a missing record fails" rr
rrmk; rrrec "$(rrhash)" "VERDICT: BLOCKED\nHIGH: real problem\n"
expect fail "review record: findings in the record fail" rr
rrmk; rrrec "$(rrhash)" "VERDICT: BLOCKED\n"
expect fail "review record: a bare BLOCKED in the record fails" rr
rrmk; rrrec "$(rrhash)" "VERDICT: APPROVED\nMEDIUM: still a finding\n"
expect fail "review record: APPROVED beside a finding in the record fails" rr
rrmk; rrrec "$(rrhash)" "VERDICT: APPROVED\n"; printf '\ndef sub(a, b):\n    return a - b\n' >> "$tmp/rr/app.py"
expect fail "review record: a clean record for an older diff (file changed afterwards) fails as stale" rr
rrmk; rrrec "0000000000000000000000000000000000000000000000000000000000000000" "VERDICT: APPROVED\n"
expect fail "review record: a clean record naming some other diff hash fails" rr
rrmk; printf 'VERDICT: APPROVED\n' > "$tmp/rr/x"; mkdir -p "$tmp/rr/.claude/review"; cp "$tmp/rr/x" "$tmp/rr/.claude/review/final-review.txt"
expect fail "review record: a record with no REVIEWED-DIFF line fails" rr
rrmk; rrrec "$(rrhash)" "VERDICT: APPROVED\n"
expect pass "review record: APPROVED with zero findings on the final diff passes (new file reached the diff by intent-to-add)" rr
rrmk; (cd "$tmp/rr" && git add -N app.py); rrrec "$(rrhash)" "VERDICT: APPROVED\n"
expect pass "review record: the same passes when the agent had already run intent-to-add" rr
rrmk; printf 'K=1\n' > "$tmp/rr/.env.local"; printf 'k\n' > "$tmp/rr/server.pem"; rrrec "$(rrhash)" "VERDICT: APPROVED\n"
expect pass "review record: untracked secret-named files never enter the checked diff (they are excluded like the skills prescribe)" rr
# r11 finding 3: the record file itself must never be part of the hashed diff. Tracked or intent-to-add, it is rewritten after the hash is taken, so a diff that included it
# would make every record stale. The case commits the record, then writes a fresh one for the unchanged tree.
rrmk; mkdir -p "$tmp/rr/.claude/review"; printf 'REVIEWED-DIFF: x\nold\n' > "$tmp/rr/.claude/review/final-review.txt"; (cd "$tmp/rr" && git add -f .claude/review/final-review.txt app.py && git -c user.name=t -c user.email=t@t commit -q -m "$(printf 'c\n\nVerified: fixture')"); rrrec "$(rrhash)" "VERDICT: APPROVED\n"
expect pass "review record: a TRACKED record file does not make the record stale on an unchanged tree" rr
rrmk; mkdir -p "$tmp/rr/.claude/review"; printf 'seed\n' > "$tmp/rr/.claude/review/final-review.txt"; (cd "$tmp/rr" && git add -N -f .claude/review/final-review.txt); rrrec "$(rrhash)" "VERDICT: APPROVED\n"
expect pass "review record: an INTENT-TO-ADD record file does not make the record stale on an unchanged tree" rr
rrmk; mkdir -p "$tmp/rr/.claude/review"; printf 'seed\n' > "$tmp/rr/.claude/review/final-review.txt"; (cd "$tmp/rr" && git add -N -f .claude/review/final-review.txt); rrrec "$(rrhash)" "VERDICT: APPROVED\n"; printf '\ndef sub(a, b):\n    return a - b\n' >> "$tmp/rr/app.py"
expect fail "review record: a tracked or intent-to-add record still goes stale when real code changes" rr
# r12 finding 3: a git call that fails must FAIL the check (empty output from a failed diff must not match a recorded empty-diff hash), and an empty diff never validates.
EMPTYH=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
rrmk; rrrec "$(rrhash)" "VERDICT: APPROVED\n"
expect fail "review record: a git diff that exits non-zero fails the check" env FAILSUB=diff PATH="$tmp/stubgit:$PATH" python3 "$here/check-review-record.py" "$tmp/rr" "$(git -C "$tmp/rr" rev-list --max-parents=0 HEAD)"
# an untracked file the run never added makes the checker run its own intent-to-add; that git call failing must be the reported cause (not a later hash mismatch)
printf 'x=1\n' > "$tmp/rr/extra.py"; rrrec "$(rrhash)" "VERDICT: APPROVED\n"
expect pass "review record: a failing intent-to-add (index preparation) fails the check and says so" sh -c 'FAILSUB=add PATH="$1:$PATH" python3 "$2" "$3" "$4" 2>&1 | grep -q "git add -N failed"' _ "$tmp/stubgit" "$here/check-review-record.py" "$tmp/rr" "$(git -C "$tmp/rr" rev-list --max-parents=0 HEAD)"
rm -f "$tmp/rr/extra.py"
expect fail "review record: a failing untracked-file listing fails the check" env FAILSUB=ls-files PATH="$tmp/stubgit:$PATH" python3 "$here/check-review-record.py" "$tmp/rr" "$(git -C "$tmp/rr" rev-list --max-parents=0 HEAD)"
expect fail "review record: a failing index path lookup fails the check" env FAILSUB=rev-parse PATH="$tmp/stubgit:$PATH" python3 "$here/check-review-record.py" "$tmp/rr" "$(git -C "$tmp/rr" rev-list --max-parents=0 HEAD)"
rrmk; base0="$(git -C "$tmp/rr" rev-list --max-parents=0 HEAD)"; rrrec "$(rrhash)" "VERDICT: APPROVED\n"; rm -rf "$tmp/notgit"; mkdir -p "$tmp/notgit/.claude/review"; cp "$tmp/rr/.claude/review/final-review.txt" "$tmp/notgit/.claude/review/"
expect fail "review record: a directory that is not a git repo fails the check" env GIT_CEILING_DIRECTORIES="$tmp" python3 "$here/check-review-record.py" "$tmp/notgit" "$base0"
rrmk; rm -f "$tmp/rr/app.py"; rrrec "$EMPTYH" "VERDICT: APPROVED\n"
expect fail "review record: an empty diff never validates, even with the empty-input hash recorded" rr
expect pass "the real branch of the proof runs the review-record check for the two skills with a Claude reviewer" sh -c "grep -q 'check-review-record.py' '$here/review-loop-proof.sh' && grep -q -- '--audit' '$here/review-loop-proof.sh'"

# Self-test (round 3 finding 3): these cases need no private reviewer, so they MUST have run (and passed) in every mode, CHECKERS_NO_SPY=1 included.
for must in "ci.yml declares an explicit contents: read permissions block" "ci.yml checks out with persist-credentials: false" "ci.yml runs the checkers with CHECKERS_NO_SPY=1" \
  "an outside-reviewer call injected into a command is caught" "the reviewer diff command in commands/execute-codex.md lists changes in sibling folders when run from a subfolder" \
  "codex-call.sh defaults --cd to the repository top when started from a subfolder" "codex-call.sh reports a message-less JSON error event whole (usage_limit visible)" \
  "a report ending in an APPROVED status line is accepted" "a real add passes check-impl" "tmo python fallback kills a slow command with exit 124"; do
  if grep -qxF -e "$must" <<<"$ran_names"; then ok "self-test: non-spy case ran: $must"; else bad "self-test: a non-spy case was skipped or failed: $must"; fi
done
if [[ -n "${CHECKERS_NO_SPY:-}" ]]; then
  [[ $plain_ran -ge 100 ]] && ok "self-test: at least 100 cases ran without the spy ($plain_ran)" || bad "self-test: only $plain_ran cases ran without the spy (expected at least 100)"
  # WHY 120 (r9 finding 2): seven new context-file cases need the installed reviewer.sh through spy-reviewer.sh, so they skip with the others; the bound still catches a skip that swallows non-spy cases.
  [[ $skipped -lt 120 ]] && ok "self-test: fewer than 120 spy cases skipped ($skipped)" || bad "self-test: $skipped cases skipped, the skip is too wide (limit 120)"
fi
[[ -n "${CHECKERS_NO_SPY:-}" ]] && echo "CHECKERS_NO_SPY=1: skipped $skipped spy-reviewer case(s); they need the installed reviewer.sh"
exit $fail
