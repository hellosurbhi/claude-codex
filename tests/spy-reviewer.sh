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
here="$(cd "$(dirname "$0")" && pwd)"
argv=("$@")
# WHY tolerant of a missing tier: a workflow may call it as `spy <file>` instead of
# `spy <tier> <file> <out>`; the spy's job is to review what it is handed, not to police usage.
if [[ -f "${1:-}" ]]; then set -- unknown "$@"; fi
tier="${1:-}" in="${2:-}" outf="${3:-/dev/stdout}"
# WHY a fallback log path: the Bash tool of a headless run may not pass SPY_LOG through,
# and the run's repo sits directly inside the out dir the harness reads spy.log from.
SPY_LOG="${SPY_LOG:-$(cd "$(git rev-parse --show-toplevel)/.." && pwd)/spy.log}"
[[ -f "$in" ]] || { echo "spy-reviewer: input file missing: $in" >&2; exit 1; }
# WHY the function signature or body, not the word: unrelated text containing "add" must not count as the change.
has_add=no; grep -qE '(^|[^A-Za-z_])add\(|a \+ b' "$in" && has_add=yes
# WHY a separate impl flag: a tests-only diff mentions add( in assertions, which is a real change under review but not the implementation.
impl=no; grep -qE 'def add\(|return [a-z_]+ \+ [a-z_]+' "$in" && impl=yes
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
prompt="You are an independent code reviewer. Review the diff or plan below. Reply with exactly one line 'VERDICT: APPROVED' or 'VERDICT: WARNING' or 'VERDICT: BLOCKED', then four lines 'CRITICAL:', 'HIGH:', 'MEDIUM:', 'LOW:' each listing every finding at that severity or 'none'. The change is meant to add a function add(a, b) returning a + b. REVIEW.md in this repo requires a tracking comment 'review-fix-N' only if a finding names one; otherwise report only real defects. If the input is a tests-only diff written before the implementation exists (the TDD red phase), the missing add function is expected, not a defect; judge the tests themselves.

$(cat "$in")"
# WHY --no-session-persistence: a test reviewer must not write transcripts under ~/.claude/projects.
# WHY failures are kept: a crashed or unauthenticated reviewer must read as FAILED, never as a verdict.
err="$(mktemp)"; trap 'rm -f "$tmp" "$err"' EXIT
rc=0; env -u CLAUDECODE claude -p "$prompt" --model sonnet --setting-sources project --permission-mode default --no-session-persistence > "$tmp" 2> "$err" || rc=$?
# WHY strict grammar: APPROVED only counts as clean when it is the single verdict line AND all four
# severity lines say none; an APPROVED that still lists findings is a finding round.
result=NOVERDICT
if (( rc != 0 )); then
  result=FAILED
elif [[ $(grep -cE '^VERDICT:' "$tmp") == 1 && $(grep -cE '^VERDICT: ' "$tmp") == 1 && $(grep -cE '^VERDICT: (APPROVED|WARNING|BLOCKED)$' "$tmp") == 1 ]]; then
  result="$(grep -E '^VERDICT: ' "$tmp" | sed 's/VERDICT: //')"
  if [[ $result == APPROVED ]] && ! [[ $(grep -cE '^(CRITICAL|HIGH|MEDIUM|LOW): none$' "$tmp") == 4 && $(grep -cE '^(CRITICAL|HIGH|MEDIUM|LOW):' "$tmp") == 4 && $(grep -E '^(CRITICAL|HIGH|MEDIUM|LOW):' "$tmp" | cut -d: -f1 | sort -u | wc -l | tr -d ' ') == 4 && $(grep -cE '[^[:space:]]' "$tmp") == 5 ]]; then result=APPROVED_WITH_FINDINGS; fi
fi
# WHY the event log line holds the exact reply and the phase taken from the file the spy actually
# received: the checkers assert on this log (see evlog.py), not on spy.log text or the transcript.
EVLOG="${EVLOG:-$(cd "$(git rev-parse --show-toplevel)/.." && pwd)/wrapper.jsonl}"
python3 "$here/evlog.py" "$EVLOG" spy "$rc" "" "" "$in" "$tmp" "$err" -- "${argv[@]+"${argv[@]}"}"
printf 'reviewer tier=%s bytes=%s has_add=%s impl=%s result=%s\n' "$tier" "$(wc -c < "$in" | tr -d ' ')" "$has_add" "$impl" "$result" >> "$SPY_LOG"
if [[ $result == FAILED ]]; then cat "$err" "$tmp" >&2; exit 1; fi
cat "$tmp" > "$outf"
[[ "$outf" == /dev/stdout ]] || cat "$tmp"
