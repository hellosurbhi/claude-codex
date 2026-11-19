#!/usr/bin/env bash
# fake-model.sh <binary> <args...>: the stand-in for the model CLIs that the REAL reviewer.sh invokes (codex, coderabbit, claude,
# gemini). tests/spy-reviewer.sh puts tests/fake-models first on PATH and runs the installed reviewer.sh unchanged, so every
# argument, tier and base-commit rule is production's; only the final model call is replaced here (r38).
#
# WHY these fakes record what they were given and return a canned verdict: the checkers assert on what production actually did
# (which model binary ran, with which tier, against which base, with which reviewed content), never on a re-implementation of
# reviewer.sh's rules. Each run appends one `model` event to the same wrapper.jsonl the other stand-ins write.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
name="$1"; shift
EVSTART="$(python3 -c 'import time; print(time.time())')"
inf="$(mktemp)"; outf="$(mktemp)"; errf="$(mktemp)"
rc=0; shown=("$@"); base=""; head=""; dirty=""
log() {
  EV_META="bin=$name tier=${REVIEWER_TIER:-none} run=${REVIEW_RUN:-none} base=${base:-none} head=${head:-none} dirty=${dirty:-none} tree=${tree:-none}" EVSTART="$EVSTART" \
    python3 "$here/evlog.py" "${EVLOG:?}" model "$rc" "" "" "$inf" "$outf" "$errf" -- "$name" "${shown[@]+"${shown[@]}"}"
  cat "$outf"; cat "$errf" >&2; rm -f "$inf" "$outf" "$errf"
}
case "$name" in
  codex)
    # Codex is over quota for the whole usage-limit scenario: it answers like the real CLI does and writes no message.
    cat > "$inf"
    echo "ERROR: You've hit your usage limit. Upgrade to Pro, or try again at 4:04 AM." > "$errf"; rc=1 ;;
  coderabbit)
    # `coderabbit review -t committed --base <ref>` reviews COMMITTED repository state, not the input file.
    ref=""; kind=""; prev=""; for a in "$@"; do [[ $prev == --base ]] && ref="$a"; [[ $prev == -t ]] && kind="$a"; prev="$a"; done
    base="$(git rev-parse -q --verify "refs/heads/$ref" 2>/dev/null || true)"
    head="$(git rev-parse HEAD 2>/dev/null || true)"
    tree="$(python3 "$here/treehash.py" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || true)"
    # WHY ignored files count too (r40): an ignored .py module is still code the committed diff never shows. Untracked .py counts as dirty: committed-state review never sees a file that is not in a commit (r39).
    if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" || -n "$(git status --porcelain --ignored -uall -- '*.py' 2>/dev/null | grep -E '^(\?\?|!!) ' | grep -vE '(^|/)(node_modules|\.claude|__pycache__|\.pytest_cache)/' 2>/dev/null)" ]]; then dirty=1; else dirty=0; fi
    # WHY only -t committed reads the diff: any other review type did not review committed code, so no content is recorded for it (r40).
    [[ -n "$base" && "$kind" == committed ]] && git diff --no-color "$base" HEAD > "$inf" 2>/dev/null
    { echo "Review complete"; if [[ -n "${FAKE_CODERABBIT_FINDING:-}" ]]; then printf 'major [bug]\n  app.py:1\n  %s\n' "$FAKE_CODERABBIT_FINDING"; fi; } > "$outf" ;;
  claude)
    # reviewer.sh run_sonnet: claude --model M -p --setting-sources "" --settings F "<prompt with the whole input>"
    prompt=""; for a in "$@"; do prompt="$a"; done
    printf '%s' "$prompt" > "$inf"
    shown=("${@:1:$#-1}" "<prompt>")
    [[ -n "${EDIT_DURING:-}" ]] && printf 'edited while reviewing\n' >> "$EDIT_DURING"
    [[ -n "${FAKE_CLAUDE_NOISE:-}" ]] && echo "$FAKE_CLAUDE_NOISE" > "$errf"
    # WHY (r41): only a real `claude -p` review may answer. --version/--help or a missing -p is not a review, so it must not return the canned approval.
    nonreview=1; for a in "${@:1:$#-1}"; do [[ $a == -p ]] && nonreview=0; done
    for a in "$@"; do [[ $a == --version || $a == -v || $a == --help || $a == -h ]] && nonreview=1; done
    if [[ $nonreview == 1 ]]; then echo "fake-model: not a review invocation" > "$errf"; rc=2; log; exit "$rc"; fi
    case "${FAKE_CLAUDE_MODE:-clean}" in
      fail) echo "partial reply on stdout" > "$outf"; rc=3 ;;
      findings) printf 'VERDICT: APPROVED\nMEDIUM: rename x\n' > "$outf" ;;
      *) printf 'VERDICT: APPROVED\n' > "$outf" ;;
    esac ;;
  *)
    # gemini and anything else: unavailable, so `diagnose` and any stray call fail instead of reaching a live service.
    echo "fake-model: $name unavailable" > "$errf"; rc=1 ;;
esac
log
exit "$rc"
