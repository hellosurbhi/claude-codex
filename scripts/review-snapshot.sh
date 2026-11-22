#!/usr/bin/env bash
# Usage: review-snapshot.sh <base>     prints the review snapshot on stdout, exit 0 only when all of it was produced.
# contract: review-snapshot v1
# The ONE definition of "the reviewed state" (r28 finding 2): `git diff <base>` of the tracked changes plus a new-file diff for every
# untracked, non-ignored file, minus secret-named paths (.env*, *secret*, *credential*, *.pem, *.key) and the workflow's own folders
# (.claude/review, .claude/plan). The skills hash it before the reviewer runs and again after the reply, and tests/check-review-record.py
# recomputes it with this same script, so the before, after and record states cannot drift apart.
# WHY untracked files are included here: the old snapshot saw only tracked and intent-to-add changes, so a new source file created while the
# reviewer ran left the hash unchanged and the record certified a state holding unreviewed code.
# WHY a throwaway index: `git add -N` on a COPY of the index (GIT_INDEX_FILE) makes git render untracked files as new-file diffs (binary files
# as git's "Binary files differ" line, paths with spaces intact via NUL-separated input) without touching the user's real index.
# WHY fail closed: output is written only after every stage succeeded (built in a temp file, emitted last), so a failed stage leaves stdout empty
# and the exit nonzero; an empty hash input must never look like a valid snapshot. `set -e` is not used because each status is checked explicitly.
set -o pipefail
base="${1:-}"
[ -n "$base" ] || { echo "usage: review-snapshot.sh <base>" >&2; exit 2; }
top="$(git rev-parse --show-toplevel)" || exit 1
[ -n "$top" ] || exit 1
cd "$top" || exit 1
tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-snap.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
src="$(git rev-parse --git-path index)" || exit 1
case "$src" in /*) ;; *) src="$top/$src" ;; esac
# WHY the copy's mtime is forced into the past (r29 flake): git treats an index entry as "racy" (re-hash its content instead of trusting size and
# mtime) when the entry's mtime is not older than the index FILE's mtime. A plain `cp` gave the copy a fresh mtime, so a same-size edit made in
# the same second as the last index write looked unchanged and vanished from the snapshot with exit 0 (about 1 run in 40, when the clock ticked
# over mid-script). `cp -p` alone would depend on the original's timestamp; touching the copy to the epoch makes EVERY entry racy, so the
# snapshot always compares content and can never trust a stat match. If the touch fails the script exits non-zero (fail closed).
if [ -e "$src" ]; then cp "$src" "$tmp/index" && touch -t 197001020000 "$tmp/index" || exit 1; fi
export GIT_INDEX_FILE="$tmp/index"
git ls-files --others --exclude-standard -z > "$tmp/untracked" || exit 1
if [ -s "$tmp/untracked" ]; then
  # Paths the pathspecs below exclude are added too but never rendered.
  git add -N --pathspec-from-file="$tmp/untracked" --pathspec-file-nul || exit 1
fi
git diff "$base" -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' ':(top,exclude).claude/review' ':(top,exclude).claude/plan' > "$tmp/out" || exit 1
cat "$tmp/out" || exit 1
