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
out="${4:-$(mktemp -d "${TMPDIR:-/tmp}/review-loop-proof.XXXXXX")}"
mkdir -p "$out"
repo="$out/repo"; rm -rf "$repo"; mkdir -p "$repo"
fake="$here/fake-codex-call.sh"
export FAKE_LOG="$out/calls.log"; : > "$FAKE_LOG"
case "$scenario" in
  round6)      export FAKE_ROUNDS=6 FAKE_SEVERITIES="LOW MEDIUM HIGH LOW MEDIUM HIGH" ;;
  high-only)   export FAKE_ROUNDS=2 FAKE_SEVERITIES=HIGH ;;
  medium-only) export FAKE_ROUNDS=2 FAKE_SEVERITIES=MEDIUM ;;
  low-only)    export FAKE_ROUNDS=2 FAKE_SEVERITIES=LOW ;;
  failed)      export FAKE_ROUNDS=1 FAKE_FAIL=1 ;;
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
  --append-system-prompt "$seam" > "$out/session.txt" 2> "$out/session.err" || true
echo "== $skill $scenario ($src) -> $out"
cat "$FAKE_LOG"
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
all_markers() {
  local k
  for k in $(seq 1 "$FAKE_ROUNDS"); do grep -rqsw --exclude-dir=.git "review-fix-$k" "$repo" || return 1; done
}
case "$scenario" in
  failed)
    check "retried the dead review once (2 calls)" '[[ $(grep -c result=DEAD "$FAKE_LOG") -eq 2 ]]'
    check "told the user the work is UNREVIEWED" 'grep -q UNREVIEWED "$out/session.txt"' ;;
  *)
    check "every finding round ($FAKE_ROUNDS) was fixed: all markers present" all_markers
    check "a round with findings came back as round $FAKE_ROUNDS" 'grep -q "round=$FAKE_ROUNDS$" "$FAKE_LOG"'
    check "re-reviewed after the last finding round and got a clean round" 'tail -1 "$FAKE_LOG" | grep -q result=CLEAN'
    check "did not report the work UNREVIEWED" '! grep -q UNREVIEWED "$out/session.txt"' ;;
esac
exit $fail
