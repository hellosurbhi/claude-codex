#!/usr/bin/env bash
# shellcheck disable=SC2034  # WHY (file-wide): claude_rc, NOVERDICT, real_final_state, review_base and final_state are read only inside single-quoted check expressions that `check` evaluates, so shellcheck cannot see the use
# review-loop-proof.sh: runs a real headless Claude session through a review
# skill against tests/fake-codex-call.sh and checks the loop's behavior.
#
# Usage: review-loop-proof.sh <skills-source> <skill> <scenario> [out-dir]
#   skills-source: a skills directory (copied into a scratch repo's .claude/skills,
#                  loaded as project skills) or the literal `installed` (loads the
#                  user-level skills at ~/.claude/skills, the installed copies)
#   skill:         claude-codex | plan-codex | execute-codex | tdd-claude-codex | tdd-execute-codex | codex-mcp
#   scenario:      round6 | high-only | medium-only | low-only | failed | malformed |
#                  usage-limit (Codex over quota: needs a real fallback review) |
#                  real (no fake: the real installed codex-call.sh and real Codex)
#
# WHY the appended system prompt: every skill calls the wrapper at the fixed path
# ~/.claude/config/scripts/codex-call.sh. Pointing a temp HOME at a fake there
# logs Claude out (macOS keychain lookups follow HOME), and writing a fake into
# the real path would replace the live wrapper. So the run is told, once, to use
# the fake at that path. The skill text that decides when to re-review is untouched.
#
# SAFETY: the `real` scenario runs a headless agent with permission PROMPTS OFF (bypassPermissions), confined by the PreToolUse hook tests/proof-confine-hook.py to
# its scratch repo (deny by default; see that file). Every other scenario keeps acceptEdits.
#
# WHY bypassPermissions at all (cc11 real run at bd3bce6 ended UNREVIEWED; confirmed with claude 2.1.323 probes): the skills keep the plan at .claude/plan/<name>.md,
# and a headless `claude -p` run DENIES every write to an EXISTING file under .claude/ ("sensitive file") for Edit, Write and a Bash redirect alike. What was tried
# first: acceptEdits with Edit(.claude/plan/**), Edit(./.claude/plan/**), Edit(/.claude/plan/**), an absolute // rule, Edit(.claude/**), Edit(.claude/plan/p.md) and a
# PreToolUse allow hook; every one was still denied (a Write(...) rule is rejected outright, only Edit rules are read). Only bypassPermissions let the edit through.
# A real session shows the user a prompt for the same write and the user approves it, so unattended approval is what this stands in for.
# WHY the hook is what makes that safe: probed with claude 2.1.323 that a PreToolUse hook still runs and still denies a tool call under bypassPermissions (a deny-all
# hook blocked even the Read, and the edit never happened). The run therefore refuses to start unless the hook file exists, is executable and denies an out-of-bounds
# probe call fed to it directly, and it fails afterwards if the hook logged no decision. What breaks if this goes back to acceptEdits: the first round of findings can
# never be fixed in the plan file, so the loop ends UNREVIEWED every time. What breaks if the hook is loosened: an unprompted agent with the owner's home in reach.
set -euo pipefail
src="$1" skill="$2" scenario="$3"
here="$(cd "$(dirname "$0")" && pwd)"
# WHY resolved before any cd: the script cd's into the scratch repo, so a relative
# source or output path would silently point somewhere else afterwards.
[[ "$src" == installed ]] || src="$(cd "$src" && pwd)"
# WHY the real scenario needs a path that does not exist yet: the agent runs with prompts off, so its whole sandbox must be a directory this script created itself.
if [[ $scenario == real && -n "${4:-}" && -e "$4" ]]; then echo "real scenario: the out dir must not exist, the proof creates it: $4" >&2; exit 2; fi
out="${4:-$(mktemp -d "${TMPDIR:-/tmp}/review-loop-proof.XXXXXX")}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
# WHY refuse a non-empty out dir instead of wiping it: the caller supplies the
# path, and deleting anything inside a directory this script did not create could
# destroy an unrelated checkout.
if [[ -n "$(ls -A "$out")" ]]; then echo "out dir must be empty: $out" >&2; exit 2; fi
repo="$out/repo"; mkdir -p "$repo"
fake="$here/fake-codex-call.sh"
export FAKE_LOG="$out/calls.log"; : > "$FAKE_LOG"
# WHY one wrapper event log: every stand-in wrapper appends a JSON line per real execution and the
# checkers assert on it alone (see evlog.py); transcript text is only a secondary sanity check.
export EVLOG="$out/wrapper.jsonl"; : > "$EVLOG"
case "$scenario" in
  round6)      export FAKE_ROUNDS=6 FAKE_SEVERITIES="LOW MEDIUM HIGH LOW MEDIUM HIGH" ;;
  high-only)   export FAKE_ROUNDS=2 FAKE_SEVERITIES=HIGH ;;
  medium-only) export FAKE_ROUNDS=2 FAKE_SEVERITIES=MEDIUM ;;
  low-only)    export FAKE_ROUNDS=2 FAKE_SEVERITIES=LOW ;;
  failed)      export FAKE_ROUNDS=1 FAKE_FAIL_FIRST=2 FAKE_FAIL_MODES="dead dead" FAKE_SEVERITIES=HIGH ;;
  malformed)   export FAKE_ROUNDS=1 FAKE_FAIL_FIRST=4 FAKE_FAIL_MODES="empty noverdict dup bad" FAKE_SEVERITIES=HIGH ;;
  usage-limit) export FAKE_ROUNDS=0 FAKE_LIMIT=1 ;;
  real)        export FAKE_ROUNDS=0 ;;
  *) echo "unknown scenario: $scenario" >&2; exit 2 ;;
esac
case "$skill" in plan-codex) export FAKE_TARGET=plan ;; *) export FAKE_TARGET=code ;; esac
# WHY a relay seam for execute-codex and tdd-execute-codex: their review loop is run by a
# code-reviewer Task agent, not by codex-call.sh, so the scripted reviewer cannot be reached
# by swapping the wrapper alone. The agent is told to relay the fake's output verbatim; the
# skill text deciding when to re-review is untouched. (Their Codex test audit and any Codex
# implementation call still go through the wrapper seam.)
relay=""
spy="$here/spy-reviewer.sh"
[[ $scenario == usage-limit ]] && relay=" Wherever a skill says ~/.claude/config/scripts/reviewer.sh, run $spy with the same arguments instead."
# WHY not in usage-limit: there the code-reviewer agent must stay a real reviewer, or the
# scenario would only prove a relay of a scripted error.
case "$skill:$scenario" in execute-codex:usage-limit|tdd-execute-codex:usage-limit) ;; execute-codex:*|tdd-execute-codex:*)
  relay="$relay Wherever the skill launches a code-reviewer Task agent, tell that agent its whole job is to run \`$fake --sandbox read-only --cd <repo> \"<review prompt>\"\` and return its stdout verbatim as the review (it adds no findings of its own and removes none); the agent has no other reviewer.";;
esac
cd "$repo"
git init -q
# WHY no origin remote (cc11-main-r1): the quota fallback must work in local repos and scratch folders that have none (scripts/codex-call.sh
# runs plan audits from scratch folders). An older reviewer.sh exited without an origin, so this fixture used to add one, which hid that
# bug. The installed reviewer.sh now falls back to a basename slug; adding an origin back here would stop the proof covering that path.
printf 'def greet(name):\n    return "hi " + name\n' > app.py
cat > REVIEW.md <<'MD'
# Review rules
Each review finding names a tracking marker such as `review-fix-N`. Adding a
comment line containing that marker to the changed file is the complete fix for
that finding; it is a real requirement of this repo, not a preference.
MD
if [[ "$src" == installed ]]; then
  sources=user
else
  mkdir -p .claude/skills
  cp -RL "$src/$skill" .claude/skills/
  sources=project
fi
git add -A && git -c user.name=proof -c user.email=proof@example.invalid commit -qm init -m 'Verified: proof fixture, nothing to check'
case "$skill" in
  claude-codex) task="/claude-codex Add a function add(a, b) to app.py that returns a + b." ;;
  plan-codex)   task="/plan-codex Add a function add(a, b) to app.py that returns a + b." ;;
  codex-mcp) task="/codex-mcp Add a function add(a, b) to app.py that returns a + b, then follow the guide: ask Codex to review the change, resume the same thread by THREAD_ID for follow-ups, fix every finding and re-review until Codex returns a clean verdict." ;;
  execute-codex)
    # WHY a large task for the Codex-touching scenarios: a small change is implemented and
    # reviewed by Claude only (Route A), so no Codex call would ever happen to observe.
    if [[ $scenario == real || $scenario == usage-limit ]]; then
      task="/execute-codex Create four new modules, each with a documented function and a doctest: mathops.py (add(a, b) returning a + b, plus sub), strops.py (shout(s)), listops.py (first(xs)), and pkginfo.py (VERSION string and describe()). Roughly 60 lines across the four files."
    else
      task="/execute-codex Add a function add(a, b) to app.py that returns a + b."
    fi ;;
  tdd-claude-codex) task="/tdd-claude-codex Add a function add(a, b) to app.py that returns a + b. Tests use python3 unittest in test_app.py, run with python3 -m unittest." ;;
  tdd-execute-codex) task="/tdd-execute-codex Add a function add(a, b) to app.py that returns a + b. Tests use python3 unittest in test_app.py, run with python3 -m unittest." ;;
  *) echo "unknown skill: $skill" >&2; exit 2 ;;
esac
seam="TEST HARNESS: for this run the Codex wrapper lives at $fake. Wherever a skill says ~/.claude/config/scripts/codex-call.sh, including its availability check, run $fake with the same arguments instead.$relay Everything else in the skill applies unchanged. You are running unattended: never wait for user input."
# WHY a follow-up request in the real scenario: real Codex often approves a trivial change on
# round 1, so without it nothing would exercise `codex-call.sh --resume THREAD_ID`.
# WHY it must not be the last call (cc11 real run at 269e440+bf4359c): the model sent the confirmation AFTER the approving re-audit, Codex answered it with a sentence
# plus the VERDICT line, and the final-state check rightly refused prose around the verdict, so a correct run read as failed. The check stays strict; the task says where the follow-up goes.
[[ $scenario == real ]] && task="$task After Codex's first reply (its verdict, or its completion report when it implements), send it one follow-up in the same thread (resume by THREAD_ID) asking it to confirm that reply. Send it before any later review round, so the last Codex call of the run is still the skill's own final review of the finished work; if no review round follows it, ask Codex to answer that follow-up with its VERDICT line only. Report the thread id."
# WHY stream-json: the real scenario must show the THREAD_ID and VERDICT lines Codex actually
# returned and whether a follow-up used --resume; those live in tool calls and results,
# not in the final report.
# WHY a PATH shim in real: the installed skill and the installed codex-call.sh run untouched; the
# wrapper resolves `codex` through PATH, the shim logs the call (see shim/codex) and runs the real binary.
if [[ $scenario == real ]]; then
  seam="You are running unattended: never wait for user input. Use the real Codex wrapper at its normal path."
  REAL_CODEX="$(command -v codex)"; export REAL_CODEX
  # WHY a nonce, the wrapper hash and the real binary path: the real-scenario checkers accept a run only when the shim recorded
  # all three from the process table (see shim/codex), so a bare or fake call cannot be counted as wrapper evidence.
  export PROOF_REPO="$repo"  # WHY: the shim hashes this repo for the final-state binding (r9 finding 1)
  EVNONCE="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"; export EVNONCE
  WRAPPER_SHA256="$(shasum -a 256 "$HOME/.claude/config/scripts/codex-call.sh" | cut -d' ' -f1)"; export WRAPPER_SHA256
  EXPECT_CODEX="$REAL_CODEX"; export EXPECT_CODEX
  export PATH="$here/shim:$PATH"
  # WHY the wrapper logs its early exits into the shim's log (r23): a call that fails before it reaches codex (bad arguments, a missing prompt file) never touches the shim, so without this an earlier clean review stood as the last word.
  export CODEX_CALL_EVENT_LOG="$EVLOG"
fi
# WHY claude -p below takes < /dev/null (cc11 r36): it reads stdin, and an open terminal or pipe makes it wait before it starts.
if [[ $scenario == real ]]; then
  hook="$here/proof-confine-hook.py"
  if [[ ! -f "$hook" || ! -x "$hook" ]]; then echo "REJECT: the confinement hook is missing or not executable: $hook" >&2; exit 2; fi
  export PROOF_SCRATCH_ROOT="$repo" PROOF_HOOK_LOG="$out/hook.log"; : > "$PROOF_HOOK_LOG"
  # WHY two probes through the real hook file before any model runs: a hook that allows everything (or crashes open) would leave the agent unconfined. The out-of-bounds
  # write must be denied and the in-bounds plan write allowed; no model is involved.
  probe() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$repo" "$1" | "$hook" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])'; }
  if [[ "$(probe "$out/../outside-probe.txt" 2>/dev/null)" != deny || "$(probe "$repo/.claude/plan/probe.md" 2>/dev/null)" != allow ]]; then echo "REJECT: the confinement hook probe failed (out-of-bounds call not denied or in-bounds call not allowed)" >&2; exit 2; fi
  : > "$PROOF_HOOK_LOG"
  printf '{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"python3 %s"}]}]}}\n' "$hook" > "$out/proof-settings.json"
  perm=(--permission-mode bypassPermissions --settings "$out/proof-settings.json" --allowedTools "Bash Read Edit Write Glob Grep Task Agent Skill")
else
  perm=(--permission-mode acceptEdits --allowedTools "Bash Read Edit Write Glob Grep Task Agent Skill Edit(./.claude/plan/**) Edit(.claude/plan/**)")
fi
claude -p "$task" --model sonnet --setting-sources "$sources" "${perm[@]}" \
  --append-system-prompt "$seam" --no-session-persistence --output-format stream-json --verbose > "$out/stream.jsonl" 2> "$out/session.err" < /dev/null && claude_rc=0 || claude_rc=$?
python3 - "$out" <<'PY'
import json, sys
o = sys.argv[1]; res = ""; ev = []; jl = []
def text(c):
    # tool_result content is a string or a list of text blocks; keep real newlines either way
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c if isinstance(b, dict))
    return str(c)
for l in open(o + "/stream.jsonl"):
    try: e = json.loads(l)
    except ValueError: continue
    if e.get("type") == "result": res = e.get("result", "")
    m = e.get("message")
    if isinstance(m, dict) and isinstance(m.get("content"), list):
        for c in m["content"]:
            if not isinstance(c, dict): continue
            if c.get("type") == "tool_use" and c.get("name") == "Bash":
                cmd = str(c["input"].get("command", ""))[:400000]
                ev.append("CMD " + cmd); jl.append({"kind": "cmd", "id": c.get("id"), "text": cmd})
            elif c.get("type") == "tool_use" and c.get("name") in ("Task", "Agent"):
                jl.append({"kind": "agent", "id": c.get("id"), "text": json.dumps(c.get("input", {}))[:400000]})
            if c.get("type") == "tool_result":
                t = text(c.get("content"))[:400000]
                ev.append("OUT " + t); jl.append({"kind": "result", "id": c.get("tool_use_id"), "text": t, "error": bool(c.get("is_error"))})
open(o + "/session.txt", "w").write(res)
open(o + "/events.txt", "w").write("\n".join(ev))
open(o + "/events.jsonl", "w").write("\n".join(json.dumps(x) for x in jl))
PY
echo "== $skill $scenario ($src) -> $out"
cat "$FAKE_LOG"
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
all_markers() {
  local k
  for k in $(seq 1 "$FAKE_ROUNDS"); do
    if [[ $FAKE_TARGET == plan ]]; then
      grep -Eqs -- "^[[:space:]]*<!--[[:space:]]*review-fix-${k}[[:space:]]*-->[[:space:]]*$" "$repo"/.claude/plan/*.md || return 1
    else
      # WHY app.py or test files: the tdd skills audit the tests before the code exists.
      grep -Eqs -- "^[[:space:]]*#[[:space:]]*review-fix-$k([^0-9].*)?$" "$repo"/app.py "$repo"/test*.py || return 1
    fi
  done
}
# WHY the scripted-reviewer checks read the wrapper event log (check-scripted.py), not calls.log: a call that died before
# writing calls.log would leave an earlier CLEAN standing as the last word (r17).
rounds_in_order() { python3 "$here/check-scripted.py" "$out/wrapper.jsonl" rounds "$FAKE_ROUNDS"; }
check "claude session exited 0" '[[ $claude_rc -eq 0 ]]'
if [[ $scenario == real ]]; then
  check "the confinement hook ran (it logged at least one decision)" '[[ -s "$out/hook.log" ]]'
  echo "HOOK DECISIONS: allow=$(grep -c '^ALLOW' "$out/hook.log" || true) deny=$(grep -c '^DENY' "$out/hook.log" || true)"
  grep '^DENY' "$out/hook.log" | sed 's/^/HOOK /' || true
fi
check "session produced a report" '[[ -s "$out/session.txt" ]]'
if [[ $scenario == real ]]; then
  NOVERDICT=; [[ $skill == execute-codex ]] && NOVERDICT=1
  # Real Codex: no scripted findings, so check what is observable: a real call returned
  # a THREAD_ID and a valid single VERDICT, and (workflows that follow up) a --resume was used.
  # WHY mechanics, not a clean final verdict: real Codex output is not scripted, so whether it
  # approves is not the harness's to demand; what must hold is that a real call returned a
  # THREAD_ID and verdict, and that a follow-up through --resume came back on the SAME thread
  # with a verdict. The last real verdict is printed for the record.
  # All real-run checks assert on the wrapper log (wrapper.jsonl, written by the PATH `codex` shim under
  # the untouched installed wrapper); the transcript is only the secondary line below.
  check "a real codex-call.sh execution exited 0 and returned a THREAD_ID" 'python3 "$here/check-real-basic.py" "$out/wrapper.jsonl" thread'
  # WHY not execute-codex: Codex implements there (no review verdict); its follow-up reply is checked for the thread only.
  [[ $skill == execute-codex ]] || check "a real Codex reply carried a single valid VERDICT" 'python3 "$here/check-real-basic.py" "$out/wrapper.jsonl" verdict'
  check "the --resume follow-up returned on the same wrapper-issued thread with a verdict" 'python3 "$here/check-resume.py" "$out/wrapper.jsonl" --real ${NOVERDICT:+--no-verdict}'
  # WHY the final-result check (cc11-main-r8 change B, r9 finding 1): the historical checks above would pass a run whose LAST review was BLOCKED, whose last call failed, or whose last clean verdict was
  # for an earlier state, while the agent still reported APPROVED. It is the SAME mechanism as the scripted branch (check-scripted.py final, bound to the state hash the shim recorded at each call);
  # for tdd-claude-codex the last clean call must also be the implementation review (impl=yes), because a clean TEST AUDIT followed by implementation edits is not a reviewed implementation.
  # WHY execute-codex and tdd-execute-codex are not held to the wrapper-log final verdict (r10 finding 2): their implementation review is a Claude code-reviewer agent (skills/tdd-execute-codex/SKILL.md
  # Route A step 7 and Step B4), so the wrapper log holds no implementation verdict, and Codex only AUDITS the tests there. What each skill prescribes instead is bound here:
  # (a) tdd-execute-codex: the LAST Codex test-audit verdict was clean (--audit); (b) both: the review record .claude/review/final-review.txt, written after every reviewer round, holds a clean
  # verdict for a diff hash equal to the diff the run ended with (check-review-record.py), so a stale or findings record, or none, fails.
  real_final_state="$(python3 "$here/state-hash.py" "$repo")"
  review_base="$(git -C "$repo" rev-list --max-parents=0 HEAD | tail -1)"
  IMPLFLAG=; [[ $skill == tdd-claude-codex ]] && IMPLFLAG=--impl
  case "$skill" in
    execute-codex|tdd-execute-codex)
      [[ $skill == tdd-execute-codex ]] && check "the last real Codex test-audit verdict exited 0 and was clean (APPROVED, zero findings)" 'python3 "$here/check-scripted.py" "$out/wrapper.jsonl" final "$real_final_state" --real --audit'
      check "the Claude reviewer's recorded verdict is clean (APPROVED, zero findings) for the diff the run ended with" 'python3 "$here/check-review-record.py" "$repo" "$review_base"';;
    *)
      check "the reported approval agrees with the FINAL reviewer result: the last real call exited 0 with a clean verdict, for the state the run ended in${IMPLFLAG:+, on the implementation}, and nothing came after it" 'python3 "$here/check-scripted.py" "$out/wrapper.jsonl" final "$real_final_state" --real $IMPLFLAG';;
  esac
  echo "LAST_VERDICT: $(python3 "$here/last-verdict.py" "$out/wrapper.jsonl")"
  echo "THREAD_IDS: $(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; print(" ".join(sorted({e["thread_id"] for e in wlog.load(sys.argv[2]) if e["thread_id"]})))' "$here" "$out/wrapper.jsonl")"
  echo "SECONDARY (transcript): resume mentions=$(grep -c -- '--resume' "$out/events.txt")"
  # WHY the behavioral acceptance step (cc11-main-r6): thread mechanics alone let a run that built nothing pass; the requested work must exist and work.
  check "the requested work exists and behaves (behavioral)" 'bash "$here/check-behavior.sh" "$skill" "$repo" "$scenario"'
  [[ $skill == codex-mcp ]] || check "final report ends with one AUDIT-STATUS: APPROVED line" 'python3 "$here/audit-status.py" "$out/session.txt" --expect APPROVED'
  exit $fail
fi
if [[ $scenario == usage-limit ]]; then
  # Codex is over quota for the whole run. A workflow that keeps its gate must get a real
  # fallback review of the actual change and only finish after a clean verdict from it.
  # WHY also the event stream: the model may point FAKE_LOG elsewhere for its own call, but the quota error text still reaches its tool results.
  check "Codex was tried and reported the usage limit" 'python3 "$here/check-limit-hit.py" "$out/wrapper.jsonl"'
  # execute-codex reviews with a Claude code-reviewer agent by design (Codex only implements
  # large changes), so the spy is never the reviewer there; only the Codex attempt and an
  # honest report are checked for it.
  if [[ $skill == execute-codex ]]; then
    # execute-codex reviews with a Claude agent by design and Codex only implements large
    # changes, so the spy is never the reviewer; what must hold is that the work still got
    # done and reviewed instead of being abandoned on the quota error.
    check "the Codex implementation call hit the usage limit" 'python3 "$here/check-limit-hit.py" "$out/wrapper.jsonl"'
    check "the change was still made (not abandoned on the quota error)" 'python3 "$here/check-modules.py" "$repo"'
    # WHY ordering and a completed result: an implementation agent must not count as the review. The
    # review is an agent whose input mentions review, started after the Codex usage-limit reply, with a result.
    # WHY the log, not an agent: on quota the review must come from a non-implementer fallback reviewer (reviewer.sh -> spy), which logs.
    check "the final clean review after the quota hit came from a fallback reviewer on the implementation phase" 'python3 "$here/check-reviewer-after-limit.py" "$out/wrapper.jsonl" --phase implementation --repo "$repo" --context'
    [[ $skill == codex-mcp ]] || check "final report ends with one AUDIT-STATUS: APPROVED line" 'python3 "$here/audit-status.py" "$out/session.txt" --expect APPROVED'
    exit $fail
  fi
  check "the requested work exists and behaves (behavioral)" 'bash "$here/check-behavior.sh" "$skill" "$repo" "$scenario"'
  # WHY all of these read the wrapper log: the last spy execution after the quota hit is the final fallback review.
  if [[ $FAKE_TARGET == code ]]; then
    check "the last fallback review after the quota hit was for the implementation and exactly clean" 'python3 "$here/check-reviewer-after-limit.py" "$out/wrapper.jsonl" --phase implementation --repo "$repo" --context'
  else
    check "the last fallback review after the quota hit was exactly clean and of the current non-empty plan" 'python3 "$here/check-reviewer-after-limit.py" "$out/wrapper.jsonl" --plan-file "$(ls -t "$repo"/.claude/plan/*.md 2>/dev/null | head -1)" --context'
  fi
  if [[ $FAKE_TARGET == code ]]; then check "the implementation really adds (behavioral)" 'python3 "$here/check-impl.py" "$repo/app.py"'; fi
  [[ $skill == codex-mcp ]] || check "final report ends with one AUDIT-STATUS: APPROVED line" 'python3 "$here/audit-status.py" "$out/session.txt" --expect APPROVED'
  exit $fail
fi
check "every finding round ($FAKE_ROUNDS) was fixed: all markers present" all_markers
check "reviewer calls reached finding rounds 1..$FAKE_ROUNDS in order" rounds_in_order
# WHY bind the clean verdict to the final state: edits made after the last CLEAN review would
# otherwise ship unreviewed. The hash is computed exactly as the fake computes it.
final_state="$(python3 "$here/state-hash.py" "$repo")"
check "the last execution was a clean reply for the state the run ended in" 'python3 "$here/check-scripted.py" "$out/wrapper.jsonl" final "$final_state"'
# WHY: the tdd skills audit tests first and that audit consumes every scripted finding, so a run
# that skipped the implementation review would still end CLEAN; require the last review saw add().
if [[ $FAKE_TARGET == code ]]; then
  check "the last clean review happened after add() was implemented" 'python3 "$here/check-scripted.py" "$out/wrapper.jsonl" final "$final_state" --impl'
fi
if [[ $scenario == failed || $scenario == malformed ]]; then
  check "the first $FAKE_FAIL_FIRST calls returned no valid verdict, the next one did, and none after" 'python3 "$here/check-scripted.py" "$out/wrapper.jsonl" failfirst "$FAKE_FAIL_FIRST"'
fi
check "the requested work exists and behaves (behavioral)" 'bash "$here/check-behavior.sh" "$skill" "$repo" "$scenario"'
[[ $skill == codex-mcp ]] || check "final report ends with one AUDIT-STATUS: APPROVED line" 'python3 "$here/audit-status.py" "$out/session.txt" --expect APPROVED'
exit $fail
