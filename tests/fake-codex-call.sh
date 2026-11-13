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
here="$(cd "$(dirname "$0")" && pwd)"
argv=("$@")
dir="$PWD" resume=""
while [[ $# -gt 1 ]]; do
  case "$1" in
    --sandbox|--role) shift 2 ;;
    --resume) resume="$2"; shift 2 ;;
    --cd) dir="$2"; shift 2 ;;
    *) break ;;
  esac
done
prompt="${1:-}"
# WHY every execution is logged by an EXIT trap: the checkers assert on this log (see evlog.py),
# so a call that dies, limits or returns garbage must still leave exactly one line. stdout and
# stderr are captured to files and replayed so the log holds the exact reply the model saw.
EVLOG="${EVLOG:-$(cd "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")/.." && pwd)/wrapper.jsonl}"
[[ -f "$EVLOG" ]] || : > "$EVLOG"
# WHY the call log is pinned next to the event log, ignoring any FAKE_LOG the caller sets: the checks read it, and a
# model that exports its own FAKE_LOG (seen in a rep that read this script) would otherwise make real calls vanish from it.
FAKE_LOG="$(dirname "$EVLOG")/calls.log"; export FAKE_LOG
EVSTART="$(python3 -c 'import time; print(time.time())')"; export EVSTART
tid="" ; [[ -n "$resume" ]] && tid="$resume"
exec 3>&1 4>&2
o="$(mktemp)"; e="$(mktemp)"; pf="$(mktemp)"; printf '%s' "$prompt" > "$pf"
exec >"$o" 2>"$e"
finish() {
  local rc=$?
  exec 1>&3 2>&4
  EV_META="${EV_META:-}" python3 "$here/evlog.py" "$EVLOG" fake "$rc" "$resume" "$tid" "$pf" "$o" "$e" -- "${argv[@]+"${argv[@]}"}"
  cat "$o"; cat "$e" >&2; rm -f "$o" "$e" "$pf"
  exit "$rc"
}
trap finish EXIT
# WHY a resume of an unknown thread dies: the real wrapper fails on a thread Codex never issued,
# so a model that invents or mistypes a thread id must not get a quiet success.
if [[ -n "$resume" ]] && ! python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wlog; e = wlog.load(sys.argv[2]); sys.exit(0 if sys.argv[3] in wlog.issued_before(e, len(e)) else 1)' "$here" "$EVLOG" "$resume"; then
  echo "codex-call: Codex turn did not complete (call died). Treat as UNREVIEWED." >&2
  echo "ERROR: no rollout found for thread id $resume" >&2
  exit 1
fi
# WHY a random suffix, not the sequence number: concurrent calls must never share a thread id (r12).
[[ -z "$resume" ]] && tid="fake-thread-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
# FAKE_LIMIT=1: every call fails the way Codex does when the account is over quota,
# naming its reset time (the wrapper passes this text through on a dead call).
if [[ -n "${FAKE_LIMIT:-}" ]]; then
  n=1; [[ -f "$FAKE_LOG" ]] && n=$(( $(wc -l < "$FAKE_LOG") + 1 ))
  printf 'call=%s resume=%s result=LIMIT\n' "$n" "${resume:-new}" >> "$FAKE_LOG"
  echo "codex-call: Codex turn did not complete (call died). Treat as UNREVIEWED." >&2
  echo "ERROR: You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), or try again at 11:42 PM." >&2
  exit 1
fi
n=1; [[ -f "$FAKE_LOG" ]] && n=$(( $(wc -l < "$FAKE_LOG") + 1 ))
bad=0; [[ -f "$FAKE_LOG" ]] && bad=$(grep -cE 'result=(DEAD|MALFORMED)' "$FAKE_LOG" || true)
if (( bad < ${FAKE_FAIL_FIRST:-0} )); then
  read -r -a modes <<< "${FAKE_FAIL_MODES:-dead}"
  mode=${modes[$(( bad % ${#modes[@]} ))]}
  if [[ $mode == dead ]]; then
    export EV_META="result=DEAD"
    printf 'call=%s resume=%s result=DEAD\n' "$n" "${resume:-new}" >> "$FAKE_LOG"
    echo "codex-call: Codex turn did not complete (call died). Treat as UNREVIEWED." >&2
    exit 1
  fi
  export EV_META="result=MALFORMED mode=$mode"
  printf 'call=%s resume=%s result=MALFORMED mode=%s\n' "$n" "${resume:-new}" "$mode" >> "$FAKE_LOG"
  case "$mode" in
    empty) ;;
    noverdict) echo "THREAD_ID: $tid"; echo "Looks fine to me overall, nothing stands out." ;;
    dup) echo "THREAD_ID: $tid"; printf 'VERDICT: APPROVED\nVERDICT: BLOCKED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n' ;;
    bad) echo "THREAD_ID: $tid"; printf 'VERDICT: MAYBE\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n' ;;
  esac
  exit 0
fi
# FAKE_TARGET=code: the marker is a '#' comment line in app.py or a test*.py file; FAKE_TARGET=plan: an
# HTML comment line in the plan file. A heading or sentence that merely mentions
# the marker does not count.
marker_present() {
  if [[ ${FAKE_TARGET:-code} == plan ]]; then
    grep -Eqs -- "^[[:space:]]*<!--[[:space:]]*review-fix-${1}[[:space:]]*-->[[:space:]]*$" "$2"/.claude/plan/*.md
  else
    grep -Eqs -- "^[[:space:]]*#[[:space:]]*review-fix-$1([^0-9].*)?$" "$2"/app.py "$2"/test*.py
  fi
}
rounds=${FAKE_ROUNDS:-6}
read -r -a sevs <<< "${FAKE_SEVERITIES:-HIGH}"
next=0
for ((k = 1; k <= rounds; k++)); do
  # WHY a comment line in the changed file only: a marker quoted in notes, REVIEW.md
  # or the session log must not count as the fix being made.
  marker_present "$k" "$dir" || { next=$k; break; }
done
# WHY a state hash and an impl flag on every call: a CLEAN verdict only means something if it
# was given for the state the run ended in, and (for the tdd skills) after add() existed.
# WHY the brace group with || true: an unmatched glob makes cat exit nonzero, which pipefail would turn into a dead fake.
state="$(python3 "$(dirname "$0")/state-hash.py" "$dir")"
impl=no; python3 "$(dirname "$0")/check-impl.py" "$dir/app.py" && impl=yes
echo "THREAD_ID: $tid"
if [[ $next == 0 ]]; then
  # WHY the same line goes into the event (EV_META): the checks read the wrapper log, so a call that died before
  # writing calls.log (an unknown-thread resume) cannot leave an earlier CLEAN standing as the last word (r17).
  export EV_META="$(printf 'result=CLEAN state=%s impl=%s' "$state" "$impl")"
  printf 'call=%s resume=%s result=CLEAN state=%s impl=%s\n' "$n" "${resume:-new}" "$state" "$impl" >> "$FAKE_LOG"
  printf 'VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n'
  exit 0
fi
sev=${sevs[$(( (next - 1) % ${#sevs[@]} ))]}
case "$sev" in CRITICAL) verdict=BLOCKED ;; HIGH) verdict=WARNING ;; *) verdict=APPROVED ;; esac
export EV_META="$(printf 'result=%s round=%s state=%s impl=%s' "$sev" "$next" "$state" "$impl")"
printf 'call=%s resume=%s result=%s round=%s state=%s impl=%s\n' "$n" "${resume:-new}" "$sev" "$next" "$state" "$impl" >> "$FAKE_LOG"
echo "VERDICT: $verdict"
for s in CRITICAL HIGH MEDIUM LOW; do
  if [[ $s == "$sev" ]]; then
    echo "$s: REVIEW.md requires the tracking marker for this round and it is missing. Fix: add a comment line containing \`review-fix-$next\` to the changed file (in app.py as a # comment; in a plan file as an HTML comment line \`<!-- review-fix-$next -->\` under a 'Review log' heading)."
  else
    echo "$s: none"
  fi
done
