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
EVSTART="$(python3 -c 'import time; print(time.time())')"
tmp="$(mktemp)"; err="$(mktemp)"; snap="$(mktemp)"; dout="$(mktemp)"; derr="$(mktemp)"; delivered=""; tree=""
# WHY tolerant of a missing tier: a workflow may call it as `spy <file>` instead of
# `spy <tier> <file> <out>`; the spy's job is to review what it is handed, not to police usage.
if [[ -f "${1:-}" ]]; then set -- unknown "$@"; fi
tier="${1:-}" in="${2:-}" outf="${3:-/dev/stdout}"
# WHY a fallback log path: the Bash tool of a headless run may not pass SPY_LOG through,
# and the run's repo sits directly inside the out dir the harness reads spy.log from.
SPY_LOG="${SPY_LOG:-$(cd "$(git rev-parse --show-toplevel)/.." && pwd)/spy.log}"
# WHY the event log is written by an EXIT trap: it must record the FINAL status and the reply actually delivered, including
# a missing input file or a failed output write, which a log line written mid-script would miss (r12).
EVLOG="${EVLOG:-$(cd "$(git rev-parse --show-toplevel)/.." && pwd)/wrapper.jsonl}"
finish() {
  local rc=$?
  # WHY the event holds what the delivery step actually produced ($dout and $derr, captured while delivering): the reply
  # may go to stdout, to stderr or to a file depending on the output path, and a log built from assumptions can disagree
  # with what the caller received (r20). Before delivery (a failed run) the streams are the diagnostics replayed to the caller.
  local o="$dout" errall="$derr"
  if [[ -z "$delivered" ]]; then
    o=/dev/null; errall="$err.all"; cp "$err" "$errall"; [[ $rc -eq 0 || -z "${replayed:-}" ]] || cat "$tmp" >> "$errall"
  fi
  # WHY the SNAPSHOT is logged and hashed, not the live path: the file may change while the reviewer runs, and the
  # event must describe exactly what was reviewed (r14).
  local src="$snap"; [[ -s "$snap" || -f "$in" ]] || src=/dev/null
  TREE_SHA256="$tree" EVSTART="$EVSTART" python3 "$here/evlog.py" "$EVLOG" spy "$rc" "" "" "$src" "$o" "$errall" -- "${argv[@]+"${argv[@]}"}"
  rm -f "$tmp" "$err" "$err.all" "$snap" "$dout" "$derr"
}
trap finish EXIT
[[ -f "$in" ]] || { echo "spy-reviewer: input file missing: $in" | tee "$err" >&2; exit 1; }
cp "$in" "$snap"
# WHY the code-state digest is taken at review START: it pins which code this review covered, so code changed afterwards is detectable.
tree="$(python3 "$here/treehash.py" "$(git rev-parse --show-toplevel)")"
in_live="$in"; in="$snap"
# WHY the function signature or body, not the word: unrelated text containing "add" must not count as the change.
has_add=no; grep -qE '(^|[^A-Za-z_])add\(|a \+ b' "$in" && has_add=yes
# WHY a separate impl flag: a tests-only diff mentions add( in assertions, which is a real change under review but not the implementation.
impl=no; grep -qE 'def add\(|return [a-z_]+ \+ [a-z_]+' "$in" && impl=yes
prompt="You are an independent code reviewer. Review the diff or plan below. Reply in the reviewer.sh format: a first line 'VERDICT: APPROVED' or 'VERDICT: WARNING' or 'VERDICT: BLOCKED', then one line per severity that has findings ('CRITICAL:', 'HIGH:', 'MEDIUM:', 'LOW:'). OMIT severity lines with no findings and never write 'none'. A fully clean review is exactly the one line 'VERDICT: APPROVED'. The change is meant to add a function add(a, b) returning a + b. REVIEW.md in this repo requires a tracking comment 'review-fix-N' only if a finding names one; otherwise report only real defects. If the input is a tests-only diff written before the implementation exists (the TDD red phase), the missing add function is expected, not a defect; judge the tests themselves.

$(cat "$in")"
# WHY --no-session-persistence: a test reviewer must not write transcripts under ~/.claude/projects.
# WHY failures are kept: a crashed or unauthenticated reviewer must read as FAILED, never as a verdict.
rc=0; env -u CLAUDECODE claude -p "$prompt" --model sonnet --setting-sources project --permission-mode default --no-session-persistence > "$tmp" 2> "$err" || rc=$?
# WHY strict grammar: like the real reviewer.sh, APPROVED only counts as clean when it is the ONLY non-blank line;
# an APPROVED that still lists findings or prose is a finding round.
result=NOVERDICT
if (( rc != 0 )); then
  result=FAILED
elif [[ $(grep -cE '^VERDICT:' "$tmp") == 1 && $(grep -cE '^VERDICT: ' "$tmp") == 1 && $(grep -cE '^VERDICT: (APPROVED|WARNING|BLOCKED)$' "$tmp") == 1 ]]; then
  result="$(grep -E '^VERDICT: ' "$tmp" | sed 's/VERDICT: //')"
  if [[ $result == APPROVED ]] && ! [[ $(grep -cE '[^[:space:]]' "$tmp") == 1 ]]; then result=APPROVED_WITH_FINDINGS; fi
fi
printf 'reviewer tier=%s bytes=%s has_add=%s impl=%s result=%s\n' "$tier" "$(wc -c < "$in" | tr -d ' ')" "$has_add" "$impl" "$result" >> "$SPY_LOG"
if [[ $result == FAILED ]]; then replayed=1; cat "$err" "$tmp" >&2; exit 1; fi
# WHY the delivery is captured and replayed: the reply must reach the caller exactly once whatever the output path is
# (/dev/stdout and /dev/fd/1 are the same stream as the plain echo), and the event must log what was delivered.
deliver() {
  # WHY no redirect of the shell's own error here: stderr is already the capture file, so a failed open reports its
  # diagnostic there once, and an output path of /dev/stderr resolves to the same capture file.
  cat "$tmp" > "$outf" || return 1
  [[ "$outf" -ef /dev/stdout || "$outf" -ef /dev/stderr ]] || cat "$tmp"
}
delivered=1
deliver >"$dout" 2>"$derr" || { cat "$dout"; cat "$derr" >&2; exit 1; }
cat "$dout"; cat "$derr" >&2
