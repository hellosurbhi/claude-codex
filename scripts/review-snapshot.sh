#!/usr/bin/env bash
# contract: review-snapshot v1 (source of truth: hellosurbhi/claude-codex scripts/review-snapshot.sh)
# Usage: review-snapshot.sh <base>                prints the review snapshot on stdout, exit 0 only when all of it was produced.
#        review-snapshot.sh --range <base> <head> the committed diff base..head (no excludes), canonical bytes, same flags.
#        review-snapshot.sh --files <a> <b>       a -U0 diff of two plain files (outside any repo), canonical bytes, same flags.
# The ONE definition of "the reviewed state" (r28 finding 2): `git diff <base>` of the tracked changes plus a new-file diff for every
# untracked, non-ignored file, minus secret-named paths (.env*, *secret*, *credential*, *.pem, *.key) and the workflow's own folders
# (.claude/review, .claude/plan). The skills hash it before the reviewer runs and again after the reply, and tests/check-review-record.py
# recomputes it with this same script, so the before, after and record states cannot drift apart.
# WHY untracked files are included here: the old snapshot saw only tracked and intent-to-add changes, so a new source file created while the
# reviewer ran left the hash unchanged and the record certified a state holding unreviewed code.
# WHY a throwaway index: `git add -N` on a COPY of the index (GIT_INDEX_FILE) makes git render untracked files as new-file diffs (binary files
# as git's "Binary files differ" line, paths with spaces intact via NUL-separated input) without touching the user's real index.
# WHY the copy's mtime is forced into the past (r29 flake): git treats an index entry as "racy" (re-hash its content instead of trusting size and
# mtime) when the entry's mtime is not older than the index FILE's mtime. A plain `cp` gave the copy a fresh mtime, so a same-size edit made in
# the same second as the last index write looked unchanged and vanished from the snapshot with exit 0 (about 1 run in 40, when the clock ticked
# over mid-script). `cp -p` alone would depend on the original's timestamp; touching the copy to the epoch makes EVERY entry racy, so the
# snapshot always compares content and can never trust a stat match. If the touch fails the script exits non-zero (fail closed).
# WHY fail closed: output is written only after every stage succeeded (built in a temp file, emitted last), so a failed stage leaves stdout empty
# and the exit nonzero; an empty hash input must never look like a valid snapshot. `set -e` is not used because each status is checked explicitly.
# WHY every output-shaping setting is pinned HERE and nowhere else (r29): the hash is only evidence if the same state always yields the same
# bytes. A configured diff.external or textconv driver could omit or normalise a change, and diff.noprefix, diff.mnemonicPrefix, color.ui,
# diff.context, core.abbrev, diff.renames, diff.algorithm, diff.relative, core.quotePath, autocrlf or GIT_EXTERNAL_DIFF/GIT_DIFF_OPTS in the
# environment would change the bytes. Command-line -c and flags outrank repo, user and system config, so nothing a user configures can reach
# the output. Renames are OFF on purpose: rename detection depends on similarity heuristics and diff.renames, so the reviewer sees a plain
# delete plus add, which is always complete. core.quotePath=true (the default) makes non-ASCII names print as ASCII octal escapes.
# Settings that CAN still change the bytes, because they live in the repo itself: .gitattributes `-diff`/`binary` and `diff=<driver>` with
# `diff.<driver>.binary` (they flip a file to "Binary files differ"), and clean filters that rewrite worktree content on read. Those files are
# part of the change under review, so editing them shows up in the same snapshot.
set -o pipefail
export LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1
unset GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_PAGER
CFG=(-c core.quotePath=true -c core.autocrlf=false -c core.safecrlf=false -c core.attributesFile=/dev/null -c core.abbrev=auto
     -c diff.external= -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.renames=false -c diff.algorithm=myers
     -c diff.indentHeuristic=true -c diff.context=3 -c diff.interHunkContext=0 -c diff.relative=false -c diff.submodule=short
     -c diff.ignoreSubmodules=none -c diff.wsErrorHighlight=none -c diff.colorMoved=false -c diff.suppressBlankEmpty=false
     -c color.ui=never -c color.diff=never)
DOPT=(--no-ext-diff --no-textconv --no-color --no-color-moved --no-renames --no-relative --src-prefix=a/ --dst-prefix=b/ --full-index
      --diff-algorithm=myers --indent-heuristic -U3 --inter-hunk-context=0 --ignore-submodules=none --submodule=short -O/dev/null)
canon() { git "${CFG[@]}" "$@"; }
mode="snapshot"
case "${1:-}" in
  --range) mode=range; [ $# -eq 3 ] || { echo "usage: review-snapshot.sh --range <base> <head>" >&2; exit 2; } ;;
  --files) mode=files; [ $# -eq 3 ] || { echo "usage: review-snapshot.sh --files <a> <b>" >&2; exit 2; } ;;
  *) [ -n "${1:-}" ] && [ $# -eq 1 ] || { echo "usage: review-snapshot.sh <base>" >&2; exit 2; } ;;
esac
tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-snap.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
case "$mode" in
  files)
    # git diff --no-index exits 1 when the files differ, which is the normal answer here.
    canon diff --no-index "${DOPT[@]}" -U0 -- "$2" "$3" > "$tmp/out"; rc=$?
    [ "$rc" -le 1 ] || exit 1 ;;
  range)
    top="$(canon rev-parse --show-toplevel)" || exit 1
    [ -n "$top" ] && cd "$top" || exit 1
    canon diff "${DOPT[@]}" "$2" "$3" > "$tmp/out" || exit 1 ;;
  *)
    base="$1"
    top="$(canon rev-parse --show-toplevel)" || exit 1
    [ -n "$top" ] || exit 1
    cd "$top" || exit 1
    src="$(canon rev-parse --git-path index)" || exit 1
    case "$src" in /*) ;; *) src="$top/$src" ;; esac
    if [ -e "$src" ]; then cp "$src" "$tmp/index" && touch -t 197001020000 "$tmp/index" || exit 1; fi
    export GIT_INDEX_FILE="$tmp/index"
    canon ls-files --others --exclude-standard -z > "$tmp/untracked" || exit 1
    if [ -s "$tmp/untracked" ]; then
      # Paths the pathspecs below exclude are added too but never rendered.
      canon add -N --pathspec-from-file="$tmp/untracked" --pathspec-file-nul || exit 1
    fi
    canon diff "${DOPT[@]}" "$base" -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' ':(top,exclude).claude/review' ':(top,exclude).claude/plan' > "$tmp/out" || exit 1 ;;
esac
cat "$tmp/out" || exit 1
