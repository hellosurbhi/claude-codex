#!/usr/bin/env bash
# spy-reviewer.sh: stands in for ~/.claude/config/scripts/reviewer.sh in the usage-limit scenario of tests/review-loop-proof.sh.
# Usage: spy-reviewer.sh <tier> <input-file> <output-file>   (the arguments reviewer.sh takes, passed through untouched)
#
# WHY this is only a launcher (r38): seven rounds (r32 to r38) found fidelity gaps between a hand-written spy and the real reviewer
# (tier rules, REVIEW_BASE_SHA, committed-state review, output aliasing). Now the INSTALLED reviewer.sh runs unchanged and does all
# validation; only the model CLIs it calls (codex, coderabbit, claude, gemini) are fakes on a PATH prefix (tests/fake-models). Nothing
# here knows a tier, a base rule or an output path rule, and the reply is written by production exactly once to the path it was given.
# What this adds is observation only: a private HOME (reviewer.sh keeps its cache and retry queue under $HOME/.claude/state, which a
# test must not touch), the run id that ties the fake model events to this call, the tree digest at start, and one `spy` event.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
EVSTART="$(python3 -c 'import time; print(time.time())')"
CONFIG="${SPY_CONFIG_DIR:-$HOME/.claude/config}"
REVIEWER_SH="$CONFIG/scripts/reviewer.sh"
top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
EVLOG="${EVLOG:-$(cd "$top/.." && pwd)/wrapper.jsonl}"
logo=""; priv="$(mktemp -d)"; snap="$(mktemp)"; cap_o="$(mktemp)"; cap_e="$(mktemp)"
trap 'rm -rf "$priv" "$snap" "$cap_o" "$cap_e" "$logo"' EXIT
in="${2:-}"; [[ -f "$in" ]] && cp "$in" "$snap"
# WHY the digest is taken at call start: it pins which code state this review covered, so code changed afterwards is detectable.
tree="$(python3 "$here/treehash.py" "$top" 2>/dev/null || true)"
run="$$-$RANDOM"
# WHY production gets the caller's arguments UNCHANGED (r39): the output path is part of the contract production implements. For example
# reviewer.sh runs `run_sonnet 2>/dev/null`, so a reply sent to /dev/stderr is lost in production; a launcher that substituted its own
# output file would deliver (and log) a verdict the real script never delivers. Only what production really emitted is observed:
# its stdout, its stderr and, for a regular-file output path, the file it wrote. Both streams are replayed once, nothing is re-written.
# WHY HOME is private only for this child: the skill's own shell keeps the real HOME (keychain logins follow it), while the
# reviewer's cache and queue go to a directory that is deleted afterwards. CLAUDE_CONFIG_DIR keeps reviewer.sh's own lib sourcing.
HOME="$priv" CLAUDE_CONFIG_DIR="$CONFIG" PATH="$here/fake-models:$PATH" EVLOG="$EVLOG" REVIEW_RUN="$run" REVIEWER_TIER="${1:-}" \
  bash "$REVIEWER_SH" "$@" > "$cap_o" 2> "$cap_e"
rc=$?
out="${3:-}"
logo="$(mktemp)"; cat "$cap_o" > "$logo"
[[ $rc -eq 0 && -n "$out" && "$out" != /dev/* && -f "$out" ]] && cat "$out" >> "$logo"
TREE_SHA256="$tree" EVSTART="$EVSTART" EV_META="run=$run" python3 "$here/evlog.py" "$EVLOG" spy "$rc" "" "" "$snap" "$logo" "$cap_e" -- "$@"
cat "$cap_o"; cat "$cap_e" >&2
exit "$rc"
