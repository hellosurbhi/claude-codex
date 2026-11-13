#!/usr/bin/env bash
# recording-codex-call.sh: a pass-through for the `real` scenario of tests/review-loop-proof.sh.
# It runs the REAL ~/.claude/config/scripts/codex-call.sh with the exact same arguments and
# replays its stdout, stderr and exit code unchanged, adding one line to the wrapper event log.
#
# WHY a recorder: the installed wrapper cannot log, and the checkers assert on a wrapper-side
# log (see evlog.py) instead of guessing from transcript text. Codex still does the real work.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
real="${REAL_CODEX_CALL:-$HOME/.claude/config/scripts/codex-call.sh}"
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
EVLOG="${EVLOG:-$(cd "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")/.." && pwd)/wrapper.jsonl}"
o="$(mktemp)"; e="$(mktemp)"; pf="$(mktemp)"; printf '%s' "$prompt" > "$pf"
trap 'rm -f "$o" "$e" "$pf"' EXIT
rc=0; "$real" "${argv[@]+"${argv[@]}"}" >"$o" 2>"$e" </dev/null || rc=$?
# The thread id is the one the real wrapper printed on its first line.
tid="$(sed -n 's/^THREAD_ID: //p' "$o" | head -1)"
[[ -z "$tid" && -n "$resume" ]] && tid="$resume"
python3 "$here/evlog.py" "$EVLOG" real "$rc" "$resume" "$tid" "$pf" "$o" "$e" -- "${argv[@]+"${argv[@]}"}"
cat "$o"; cat "$e" >&2
exit "$rc"
