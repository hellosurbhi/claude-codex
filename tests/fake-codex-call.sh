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
dir="$PWD" resume="" resume_set=0 pfile="" pfile_set=0 role=""
# WHY the parser mirrors scripts/codex-call.sh (r22 finding 3): a lone option, an unknown option or an extra argument must fail here exactly as in the real wrapper, so a model cannot pass the proof with a call the
# real wrapper would refuse. The error is held in $perr and raised after the logging trap exists, so the failed attempt still leaves an event.
perr=""
while [[ $# -gt 0 && -z "$perr" ]]; do
  case "$1" in
    --sandbox|--role|--resume|--cd|--prompt-file)
      if [[ $# -lt 2 ]]; then perr="option $1 needs a value"; break; fi
      if [[ "$2" == -* ]]; then perr="option $1 needs a value, not the option-like $2"; break; fi
      case "$1" in
        --role) role="$2" ;;
        --resume) resume="$2"; resume_set=1 ;;
        --cd) dir="$2" ;;
        --prompt-file) pfile="$2"; pfile_set=1 ;;
      esac
      shift 2 ;;
    --) shift; break ;;
    -*) perr="unknown option $1"; break ;;
    *) break ;;
  esac
done
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
o="$(mktemp)"; e="$(mktemp)"; pf="$(mktemp)"; prompt=""
exec >"$o" 2>"$e"
finish() {
  local rc=$?
  exec 1>&3 2>&4
  EV_META="${EV_META:-}" python3 "$here/evlog.py" "$EVLOG" fake "$rc" "$resume" "$tid" "$pf" "$o" "$e" -- "${argv[@]+"${argv[@]}"}"
  cat "$o"; cat "$e" >&2; rm -f "$o" "$e" "$pf"
  exit "$rc"
}
trap finish EXIT
# WHY the validation sits AFTER the logging trap (r21 finding 3): the checkers decide on the LAST attempt in this log. A bad-argument, missing-role or missing-prompt exit that happened before the trap
# left no event, so an earlier clean review stayed the last word. Every exit, early or late, now leaves one event with its exit code, like the real wrapper's failures are seen by the proof.
# The rules mirror scripts/codex-call.sh: empty --resume, both prompt forms, a missing or empty role file or prompt file (--prompt-file r20 finding 1) and no prompt all exit 2 with no verdict.
if [[ -n "$perr" ]]; then echo "codex-call: $perr. usage: codex-call.sh [--sandbox MODE] [--role FILE] [--resume THREAD_ID] [--cd DIR] (--prompt-file FILE | [--] PROMPT). Treat as UNREVIEWED." >&2; exit 2; fi
if [[ $resume_set -eq 1 && -z "$resume" ]]; then echo "codex-call: empty --resume value (a thread id was expected). Treat as UNREVIEWED." >&2; exit 2; fi
if [[ -n "$role" && ! -s "$role" ]]; then echo "codex-call: role file is missing, unreadable or empty: $role. No call was made; treat as UNREVIEWED." >&2; exit 2; fi
if [[ $pfile_set -eq 1 ]]; then
  if [[ $# -gt 0 ]]; then echo "codex-call: give either --prompt-file or a positional prompt, not both. Treat as UNREVIEWED." >&2; exit 2; fi
  [[ -n "$pfile" && -s "$pfile" ]] || { echo "codex-call: prompt file is missing or empty: $pfile. No call was made; treat as UNREVIEWED." >&2; exit 2; }
  prompt="$(cat "$pfile")"
elif [[ $# -lt 1 ]]; then echo "codex-call: no prompt (pass --prompt-file FILE or a prompt). usage: codex-call.sh ... Treat as UNREVIEWED." >&2; exit 2
elif [[ $# -gt 1 ]]; then echo "codex-call: unexpected extra arguments after the prompt. usage: codex-call.sh ... Treat as UNREVIEWED." >&2; exit 2
else prompt="$1"; fi
printf '%s' "$prompt" > "$pf"
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
  EV_META="$(printf 'result=CLEAN state=%s impl=%s' "$state" "$impl")"; export EV_META
  printf 'call=%s resume=%s result=CLEAN state=%s impl=%s\n' "$n" "${resume:-new}" "$state" "$impl" >> "$FAKE_LOG"
  printf 'VERDICT: APPROVED\nCRITICAL: none\nHIGH: none\nMEDIUM: none\nLOW: none\n'
  exit 0
fi
sev=${sevs[$(( (next - 1) % ${#sevs[@]} ))]}
case "$sev" in CRITICAL) verdict=BLOCKED ;; HIGH) verdict=WARNING ;; *) verdict=APPROVED ;; esac
EV_META="$(printf 'result=%s round=%s state=%s impl=%s' "$sev" "$next" "$state" "$impl")"; export EV_META
printf 'call=%s resume=%s result=%s round=%s state=%s impl=%s\n' "$n" "${resume:-new}" "$sev" "$next" "$state" "$impl" >> "$FAKE_LOG"
echo "VERDICT: $verdict"
for s in CRITICAL HIGH MEDIUM LOW; do
  if [[ $s == "$sev" ]]; then
    echo "$s: REVIEW.md requires the tracking marker for this round and it is missing. Fix: add a comment line containing \`review-fix-$next\` to the changed file (in app.py as a # comment; in a plan file as an HTML comment line \`<!-- review-fix-$next -->\` under a 'Review log' heading)."
  else
    echo "$s: none"
  fi
done
