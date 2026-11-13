#!/usr/bin/env bash
# review-loop-proof.sh: runs a real headless Claude session through a review
# skill against tests/fake-codex-call.sh and checks the loop's behavior.
#
# Usage: review-loop-proof.sh <skills-source> <skill> <scenario> [out-dir]
#   skills-source: a skills directory (copied into a scratch repo's .claude/skills,
#                  loaded as project skills) or the literal `installed` (loads the
#                  user-level skills at ~/.claude/skills, the installed copies)
#   skill:         claude-codex | plan-codex
#   scenario:      round6 | high-only | medium-only | low-only | failed
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
  failed)      export FAKE_ROUNDS=1 FAKE_FAIL_FIRST=2 FAKE_SEVERITIES=HIGH ;;
  *) echo "unknown scenario: $scenario" >&2; exit 2 ;;
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
  *) echo "unknown skill: $skill" >&2; exit 2 ;;
esac
seam="TEST HARNESS: for this run the Codex wrapper lives at $fake. Wherever a skill says ~/.claude/config/scripts/codex-call.sh, including its availability check, run $fake with the same arguments instead. Everything else in the skill applies unchanged. You are running unattended: never wait for user input."
claude -p "$task" --model sonnet --setting-sources "$sources" \
  --permission-mode acceptEdits \
  --allowedTools "Bash Read Edit Write Glob Grep Task Agent Skill Edit(./.claude/plan/**) Write(./.claude/plan/**)" \
  --append-system-prompt "$seam" > "$out/session.txt" 2> "$out/session.err" && claude_rc=0 || claude_rc=$?
echo "== $skill $scenario ($src) -> $out"
cat "$FAKE_LOG"
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
all_markers() {
  local k
  for k in $(seq 1 "$FAKE_ROUNDS"); do grep -rqsw --exclude-dir=.git "review-fix-$k" "$repo" || return 1; done
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
check "every finding round ($FAKE_ROUNDS) was fixed: all markers present" all_markers
check "reviewer calls reached finding rounds 1..$FAKE_ROUNDS in order" rounds_in_order
check "re-reviewed after the last finding round and got a clean round" 'tail -1 "$FAKE_LOG" | grep -q result=CLEAN'
if [[ $scenario == failed ]]; then
  check "first two calls died with no verdict" '[[ $(sed -n 1,2p "$FAKE_LOG" | grep -c result=DEAD) -eq 2 ]]'
  check "kept going after two dead calls (call 3 returned a verdict)" 'sed -n 3p "$FAKE_LOG" | grep -qv result=DEAD'
  check "no further dead calls after the first verdict" '[[ $(grep -c result=DEAD "$FAKE_LOG") -eq 2 ]]'
fi
check "final report does not label the work UNREVIEWED" '! grep -q UNREVIEWED "$out/session.txt"'
exit $fail
