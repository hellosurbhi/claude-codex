#!/usr/bin/env bash
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
# WHY the explicit .claude/plan allow rules: plan-codex writes its plan under
# .claude/plan/, which acceptEdits alone treats as a protected path, so the
# run stalled on denied edits instead of exercising the loop.
set -euo pipefail
src="$1" skill="$2" scenario="$3"
here="$(cd "$(dirname "$0")" && pwd)"
# WHY resolved before any cd: the script cd's into the scratch repo, so a relative
# source or output path would silently point somewhere else afterwards.
[[ "$src" == installed ]] || src="$(cd "$src" && pwd)"
out="${4:-$(mktemp -d "${TMPDIR:-/tmp}/review-loop-proof.XXXXXX")}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
# WHY refuse a non-empty out dir instead of wiping it: the caller supplies the
# path, and deleting anything inside a directory this script did not create could
# destroy an unrelated checkout.
if [[ -n "$(ls -A "$out")" ]]; then echo "out dir must be empty: $out" >&2; exit 2; fi
repo="$out/repo"; mkdir -p "$repo"
fake="$here/fake-codex-call.sh"
export FAKE_LOG="$out/calls.log"; : > "$FAKE_LOG"
case "$scenario" in
  round6)      export FAKE_ROUNDS=6 FAKE_SEVERITIES="LOW MEDIUM HIGH LOW MEDIUM HIGH" ;;
  high-only)   export FAKE_ROUNDS=2 FAKE_SEVERITIES=HIGH ;;
  medium-only) export FAKE_ROUNDS=2 FAKE_SEVERITIES=MEDIUM ;;
  low-only)    export FAKE_ROUNDS=2 FAKE_SEVERITIES=LOW ;;
  failed)      export FAKE_ROUNDS=1 FAKE_FAIL_FIRST=2 FAKE_FAIL_MODES="dead dead" FAKE_SEVERITIES=HIGH ;;
  malformed)   export FAKE_ROUNDS=1 FAKE_FAIL_FIRST=4 FAKE_FAIL_MODES="empty noverdict dup bad" FAKE_SEVERITIES=HIGH ;;
  usage-limit) export FAKE_ROUNDS=0 FAKE_LIMIT=1 SPY_LOG="$out/spy.log"; : > "$SPY_LOG" ;;
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
[[ $scenario == real ]] && task="$task After Codex's first verdict, send it one follow-up in the same thread (resume by THREAD_ID) asking it to confirm that verdict, and report the thread id."
# WHY stream-json: the real scenario must show the THREAD_ID and VERDICT lines Codex actually
# returned and whether a follow-up used --resume; those live in tool calls and results,
# not in the final report.
[[ $scenario == real ]] && seam="You are running unattended: never wait for user input. Use the real Codex wrapper at its normal path."
claude -p "$task" --model sonnet --setting-sources "$sources" \
  --permission-mode acceptEdits \
  --allowedTools "Bash Read Edit Write Glob Grep Task Agent Skill Edit(./.claude/plan/**) Edit(.claude/plan/**)" \
  --append-system-prompt "$seam" --output-format stream-json --verbose > "$out/stream.jsonl" 2> "$out/session.err" && claude_rc=0 || claude_rc=$?
python3 - "$out" <<'PY'
import json, sys
o = sys.argv[1]; res = ""; ev = []
for l in open(o + "/stream.jsonl"):
    try: e = json.loads(l)
    except ValueError: continue
    if e.get("type") == "result": res = e.get("result", "")
    m = e.get("message")
    if isinstance(m, dict) and isinstance(m.get("content"), list):
        for c in m["content"]:
            if not isinstance(c, dict): continue
            if c.get("type") == "tool_use" and c.get("name") == "Bash": ev.append("CMD " + str(c["input"].get("command", ""))[:300])
            if c.get("type") == "tool_result": ev.append("OUT " + str(c.get("content"))[:600])
open(o + "/session.txt", "w").write(res)
open(o + "/events.txt", "w").write("\n".join(ev))
PY
echo "== $skill $scenario ($src) -> $out"
cat "$FAKE_LOG"
[[ -f "$out/spy.log" ]] && cat "$out/spy.log"
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
# Each finding round K must appear as a real reviewer call, in order, then a CLEAN call after the last.
rounds_in_order() {
  local k=0 line
  while IFS= read -r line; do
    if [[ $line == *"round=$((k + 1))" ]]; then k=$((k + 1)); fi
  done < "$FAKE_LOG"
  [[ $k -eq $FAKE_ROUNDS ]]
}
check "claude session exited 0" '[[ $claude_rc -eq 0 ]]'
check "session produced a report" '[[ -s "$out/session.txt" ]]'
if [[ $scenario == real ]]; then
  # Real Codex: no scripted findings, so check what is observable: a real call returned
  # a THREAD_ID and a valid single VERDICT, and (workflows that follow up) a --resume was used.
  check "a real codex-call.sh call returned a THREAD_ID" 'grep -qE "THREAD_ID: [0-9a-f-]{8,}" "$out/events.txt"'
  check "a real Codex reply carried a VERDICT line" 'grep -qE "VERDICT: [A-Z]+" "$out/events.txt"'
  echo "THREAD_IDS: $(grep -oE 'THREAD_ID: [0-9a-f-]{8,}' "$out/events.txt" | sort -u | tr '\n' ' ')"
  echo "VERDICTS: $(grep -oE 'VERDICT: [A-Z]+' "$out/events.txt" | tr '\n' ' ')"
  check "a follow-up reached Codex through --resume" 'grep -qE "CMD .*codex-call.sh.* --resume " "$out/events.txt"'
  echo "RESUME_USED: $(grep -c -- '--resume' "$out/events.txt")"
  check "final report does not label the work UNREVIEWED" '! grep -qiE "(is|are|remains?|stays?|stay|left|labell?ed|marked) (still )?[*_]*UNREVIEWED|[:=] *[*_]*UNREVIEWED|review incomplete|audit incomplete" "$out/session.txt"'
  exit $fail
fi
if [[ $scenario == usage-limit ]]; then
  # Codex is over quota for the whole run. A workflow that keeps its gate must get a real
  # fallback review of the actual change and only finish after a clean verdict from it.
  check "Codex was tried and reported the usage limit" 'grep -q result=LIMIT "$FAKE_LOG"'
  # execute-codex reviews with a Claude code-reviewer agent by design (Codex only implements
  # large changes), so the spy is never the reviewer there; only the Codex attempt and an
  # honest report are checked for it.
  if [[ $skill == execute-codex ]]; then
    check "final report does not call the work skipped or UNREVIEWED" '! grep -qiE "audit skipped|review skipped|(is|are|remains?|stays?|labell?ed|marked) (still )?[*_]*UNREVIEWED|[:=] *[*_]*UNREVIEWED" "$out/session.txt"'
    exit $fail
  fi
  check "a fallback reviewer ran on the actual diff or plan" 'grep -q "has_add=yes" "$SPY_LOG"'
  check "the fallback returned a valid verdict" 'grep -qE "result=(APPROVED|WARNING|BLOCKED)" "$SPY_LOG"'
  check "the last fallback verdict is clean (APPROVED)" 'tail -1 "$SPY_LOG" | grep -q "result=APPROVED"'
  check "final report does not call the work skipped or UNREVIEWED" '! grep -qiE "audit skipped|review skipped|skipped|(is|are|remains?|stays?|labell?ed|marked) (still )?[*_]*UNREVIEWED|[:=] *[*_]*UNREVIEWED" "$out/session.txt"'
  exit $fail
fi
check "every finding round ($FAKE_ROUNDS) was fixed: all markers present" all_markers
check "reviewer calls reached finding rounds 1..$FAKE_ROUNDS in order" rounds_in_order
check "re-reviewed after the last finding round and got a clean round" 'tail -1 "$FAKE_LOG" | grep -q result=CLEAN'
if [[ $scenario == failed || $scenario == malformed ]]; then
  check "the first $FAKE_FAIL_FIRST calls returned no valid verdict" '[[ $(sed -n "1,${FAKE_FAIL_FIRST}p" "$FAKE_LOG" | grep -cE "result=(DEAD|MALFORMED)") -eq $FAKE_FAIL_FIRST ]]'
  check "kept going: the next call returned a verdict" 'sed -n "$((FAKE_FAIL_FIRST + 1))p" "$FAKE_LOG" | grep -qvE "result=(DEAD|MALFORMED)"'
  check "no bad calls after the first verdict" '[[ $(grep -cE "result=(DEAD|MALFORMED)" "$FAKE_LOG") -eq $FAKE_FAIL_FIRST ]]'
fi
# WHY a phrase match, not any mention of UNREVIEWED: the report may truthfully narrate
# that early calls "died with UNREVIEWED"; the failure is claiming the work still is.
check "final report does not label the work UNREVIEWED" '! grep -qiE "(is|are|remains?|stays?|stay|left|labell?ed|marked) (still )?[*_]*UNREVIEWED|[:=] *[*_]*UNREVIEWED|review incomplete|audit incomplete" "$out/session.txt"'
exit $fail
