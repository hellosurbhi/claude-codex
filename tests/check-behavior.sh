#!/usr/bin/env bash
# Usage: check-behavior.sh <skill> <repo> <scenario>   exit 0 when the work the proof asked the skill for really exists and behaves.
# WHY one shared acceptance step (cc11-main-r6 finding 2): the real scenario used to exit after thread mechanics and the reported audit status, so an execute-codex
# conversation that created none of the four requested modules passed. Every scenario branch of review-loop-proof.sh now calls this before it exits, and test-checkers.sh
# drives it on fabricated work dirs, so the acceptance rule is tested without spending Codex quota. What each skill is held to mirrors the task text the proof sends:
#   execute-codex in the real and usage-limit scenarios -> the four modules (check-modules.py); every other execute-codex run -> the small add() in app.py
#   claude-codex, tdd-claude-codex, tdd-execute-codex, codex-mcp -> a module-level add() in app.py that really adds (check-impl.py)
#   plan-codex -> a non-empty plan file under .claude/plan/ that is about the add() request
set -u
skill="${1:-}" repo="${2:-}" scenario="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"
[[ -d "$repo" ]] || { echo "check-behavior: no work dir: $repo" >&2; exit 2; }
case "$skill" in
  execute-codex)
    if [[ $scenario == real || $scenario == usage-limit ]]; then exec python3 "$here/check-modules.py" "$repo"; fi
    exec python3 "$here/check-impl.py" "$repo/app.py" ;;
  claude-codex|tdd-claude-codex|tdd-execute-codex|codex-mcp) exec python3 "$here/check-impl.py" "$repo/app.py" ;;
  plan-codex)
    for f in "$repo"/.claude/plan/*.md; do
      [[ -s "$f" ]] && grep -qiw 'add' "$f" && exit 0
    done
    echo "check-behavior: no non-empty plan file about add() under $repo/.claude/plan" >&2; exit 1 ;;
  *) echo "check-behavior: unknown skill: $skill" >&2; exit 2 ;;
esac
