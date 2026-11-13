#!/usr/bin/env bash
# fake-codex-call.sh: stands in for codex-call.sh in tests/review-loop-proof.sh.
#
# WHY: proving "the loop keeps going into round 6" and "a LOW-only round is
# re-reviewed" needs a reviewer whose findings are scripted. Real Codex finds
# whatever it finds, so it cannot prove either. Findings are tied to repo state,
# not to a call counter: round K asks for the marker `review-fix-K`, and the next
# round only starts once that marker exists, so a discussion reply (no fix) gets
# the same finding again instead of advancing the script.
#
# Env: FAKE_LOG (required) call log; FAKE_ROUNDS rounds that carry a finding;
#      FAKE_SEVERITIES space-separated severity per round, cycled (default HIGH);
#      FAKE_FAIL_FIRST=N makes the first N calls return no valid verdict, after
#      which calls behave normally; FAKE_FAIL_MODES (space-separated, cycled per
#      bad call) picks how: dead (exit 1), empty (exit 0, no text), noverdict
#      (prose only), dup (two VERDICT lines), bad (VERDICT: MAYBE).
set -euo pipefail
dir="$PWD" resume=""
while [[ $# -gt 1 ]]; do
  case "$1" in
    --sandbox|--role) shift 2 ;;
    --resume) resume="$2"; shift 2 ;;
    --cd) dir="$2"; shift 2 ;;
    *) break ;;
  esac
done
n=1; [[ -f "$FAKE_LOG" ]] && n=$(( $(wc -l < "$FAKE_LOG") + 1 ))
bad=0; [[ -f "$FAKE_LOG" ]] && bad=$(grep -cE 'result=(DEAD|MALFORMED)' "$FAKE_LOG" || true)
if (( bad < ${FAKE_FAIL_FIRST:-0} )); then
  read -r -a modes <<< "${FAKE_FAIL_MODES:-dead}"
  mode=${modes[$(( bad % ${#modes[@]} ))]}
  if [[ $mode == dead ]]; then
    printf 'call=%s resume=%s result=DEAD\n' "$n" "${resume:-new}" >> "$FAKE_LOG"
    echo "codex-call: Codex turn did not complete (call died). Treat as UNREVIEWED." >&2
    exit 1
  fi
  printf 'call=%s resume=%s result=MALFORMED mode=%s\n' "$n" "${resume:-new}" "$mode" >> "$FAKE_LOG"
  case "$mode" in
    empty) ;;
    noverdict) echo "THREAD_ID: fake-thread"; echo "Looks fine to me overall, nothing stands out." ;;
    dup) echo "THREAD_ID: fake-thread"; printf 'VERDICT: APPROVED\nVERDICT: BLOCKED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n' ;;
    bad) echo "THREAD_ID: fake-thread"; printf 'VERDICT: MAYBE\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n' ;;
  esac
  exit 0
fi
rounds=${FAKE_ROUNDS:-6}
read -r -a sevs <<< "${FAKE_SEVERITIES:-HIGH}"
next=0
for ((k = 1; k <= rounds; k++)); do
  # WHY a comment line in the changed file only: a marker quoted in notes, REVIEW.md
  # or the session log must not count as the fix being made.
  grep -Eqs -- "^[[:space:]]*(#|//|<!--).*review-fix-$k([^0-9]|\$)" "$dir/app.py" "$dir"/.claude/plan/*.md || { next=$k; break; }
done
echo "THREAD_ID: fake-thread"
if [[ $next == 0 ]]; then
  printf 'call=%s resume=%s result=CLEAN\n' "$n" "${resume:-new}" >> "$FAKE_LOG"
  printf 'VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n'
  exit 0
fi
sev=${sevs[$(( (next - 1) % ${#sevs[@]} ))]}
case "$sev" in CRITICAL) verdict=BLOCKED ;; HIGH) verdict=WARNING ;; *) verdict=APPROVED ;; esac
printf 'call=%s resume=%s result=%s round=%s\n' "$n" "${resume:-new}" "$sev" "$next" >> "$FAKE_LOG"
echo "VERDICT: $verdict"
for s in CRITICAL HIGH MEDIUM LOW; do
  if [[ $s == "$sev" ]]; then
    echo "$s: REVIEW.md requires the tracking marker for this round and it is missing. Fix: add a comment line containing \`review-fix-$next\` to the changed file (in app.py as a # comment; in a plan file as an HTML comment line \`<!-- review-fix-$next -->\` under a 'Review log' heading)."
  else
    echo "$s: none"
  fi
done
