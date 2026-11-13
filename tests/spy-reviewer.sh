#!/usr/bin/env bash
# spy-reviewer.sh: stands in for ~/.claude/config/scripts/reviewer.sh in the
# usage-limit scenario of tests/review-loop-proof.sh. Usage: spy-reviewer.sh <tier> <input-file> [output-file]
#
# WHY a spy that runs a REAL reviewer instead of scripting one: the point of the
# scenario is that, when Codex is over quota, the workflow gets a genuine independent
# review of the actual diff or plan. The real reviewer.sh writes queue and cache files
# under ~/.claude/state, which a test must not touch, so this runs a fresh Sonnet
# review of the exact input file and logs what it was given (size, whether it holds the
# task's `add` code) and the verdict it returned.
set -euo pipefail
# WHY tolerant of a missing tier: a workflow may call it as `spy <file>` instead of
# `spy <tier> <file> <out>`; the spy's job is to review what it is handed, not to police usage.
if [[ -f "${1:-}" ]]; then set -- unknown "$@"; fi
tier="${1:-}" in="${2:-}" outf="${3:-/dev/stdout}"
# WHY a fallback log path: the Bash tool of a headless run may not pass SPY_LOG through,
# and the run's repo sits directly inside the out dir the harness reads spy.log from.
SPY_LOG="${SPY_LOG:-$(cd "$(git rev-parse --show-toplevel)/.." && pwd)/spy.log}"
[[ -f "$in" ]] || { echo "spy-reviewer: input file missing: $in" >&2; exit 1; }
has_add=no; grep -q 'add' "$in" && has_add=yes
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
prompt="You are an independent code reviewer. Review the diff or plan below. Reply with exactly one line 'VERDICT: APPROVED' or 'VERDICT: WARNING' or 'VERDICT: BLOCKED', then four lines 'CRITICAL:', 'HIGH:', 'MEDIUM:', 'LOW:' each listing every finding at that severity or 'none'. The change is meant to add a function add(a, b) returning a + b. REVIEW.md in this repo requires a tracking comment 'review-fix-N' only if a finding names one; otherwise report only real defects. If the input is a tests-only diff written before the implementation exists (the TDD red phase), the missing add function is expected, not a defect; judge the tests themselves.

$(cat "$in")"
env -u CLAUDECODE claude -p "$prompt" --model sonnet --setting-sources project --permission-mode default > "$tmp" 2>/dev/null || true
verdict="$(grep -cE '^VERDICT: (APPROVED|WARNING|BLOCKED)$' "$tmp" || true)"
result=NOVERDICT; [[ "$verdict" == 1 ]] && result="$(grep -E '^VERDICT:' "$tmp" | sed 's/VERDICT: //')"
printf 'reviewer tier=%s bytes=%s has_add=%s result=%s\n' "$tier" "$(wc -c < "$in" | tr -d ' ')" "$has_add" "$result" >> "$SPY_LOG"
cat "$tmp" > "$outf"
[[ "$outf" == /dev/stdout ]] || cat "$tmp"
