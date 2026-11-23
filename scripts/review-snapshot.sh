#!/usr/bin/env bash
# contract: review-snapshot v1 (source of truth: hellosurbhi/claude-codex scripts/review-snapshot.sh)
# Usage: review-snapshot.sh <base>                prints the review snapshot on stdout, exit 0 only when all of it was produced.
#        review-snapshot.sh --range <base> <head> the committed diff base..head (no excludes), canonical bytes, same flags.
#        review-snapshot.sh --files <a> <b>       a -U0 diff of two plain files (outside any repo), canonical bytes, same flags.
# The ONE definition of "the reviewed state" (r28, redesigned r30): the working-tree files on disk as a git tree, diffed against the base tree,
# minus secret-named paths (.env*, *secret*, *credential*, *.pem, *.key) and the workflow's own folders (.claude/review, .claude/plan). The skills
# hash it before the reviewer runs and again after the reply, and tests/check-review-record.py recomputes it with this same script.
# WHY the tree is built from disk into a FRESH index and object directory, and the user's index is never used for content (r30): three rounds
# found three ways a copy of the user's index lies (racy mtime, then config, then assume-unchanged/skip-worktree flags). A stat-cache diff
# decides "unchanged" from index state the user or git controls; a tree-vs-tree diff has no stat cache, racy window, flags, fsmonitor,
# untracked cache, split or sparse index. Plain `cp` of the index, `git add -N` on a copy and a touch to 1970 were all tried first and all
# left a way for an edited file to be missing. The user's index supplies only its CURRENT ENTRIES (mode + blob id, content-addressed, never stat
# data), which paths are skip-worktree and which are gitlinks. Objects go to a temporary GIT_OBJECT_DIRECTORY (the real store is an alternate,
# read only), so the real index, refs and objects are untouched.
# THE RULE (r31): the private index starts from the CURRENT state (the real index entries), never from the base. Disk content overrides wherever a
# file exists on disk. "Absent on disk and not skip-worktree" is a deletion. The base is ONLY the left side of the final tree-vs-tree diff. WHY: r30
# started from the base, so a change committed after the base and then hidden by a sparse checkout (or an uninitialized submodule whose gitlink moved)
# silently fell back to its base content and an approval could omit committed changes.
# WHAT EACH PATH CLASS CONTRIBUTES (class -> source of mode and content -> failure behaviour). The hermetic checker has one case per row.
#   regular file or symlink on disk, any index state -> the bytes on disk (exec bit read from disk, symlink recorded as a link)
#                                                        -> fails closed if it has a filter, ident or working-tree-encoding attribute
#   untracked file ignored by the repo's own rules   -> nothing (not part of the state); the user's global ignore file is NOT applied
#   tracked file, ignored or hidden by assume-unchanged -> the bytes on disk (the index flags are never consulted for content)
#   absent on disk, tracked, not skip-worktree        -> deleted (also when removed from the index)
#   absent on disk, skip-worktree (sparse checkout)   -> the CURRENT index entry, mode and blob id (taken from the index when it differs from
#                                                        HEAD: the index is the current intended state); never a deletion, never the base
#   plain directory where the index has a file        -> the file is removed, the files below it are added from disk
#   gitlink dir with .git (initialized submodule)     -> the submodule's checked-out HEAD commit; fails closed if the submodule has any
#                                                        uncommitted or untracked change or its own snapshot fails
#   gitlink dir without .git (uninitialized)          -> the CURRENT index gitlink (a pointer moved after the base shows as the change)
#   directory with .git that is not a gitlink         -> fails closed (untracked nested repository)
#   unmerged index entry (conflict stage 1-3)         -> fails closed
#   fifo, socket or other non-regular file where a path is tracked -> fails closed (untracked ones are never listed by git)
#   path whose name contains a newline                -> fails closed
# Decisions: ignore rules are the repo's own (.gitignore, .git/info/exclude); the user's global core.excludesFile and XDG ignore are NOT applied
# (a file hidden by a private ignore must still be reviewed). The candidate paths are the non-ignored files on disk, every base path and every
# current index path, so a tracked file that is ignored or deleted is still compared. Attribute values `unspecified` and `unset` (-filter, -ident,
# -working-tree-encoding) are accepted; any other value fails closed, including filter=<name> with NO configured driver (git would treat that as a
# no-op, but a configured driver can appear later and rewrite bytes, so rejecting is the safe side) and a bare `ident`. The executable bit is
# read from disk (core.fileMode pinned true) and symlinks are recorded as links (core.symlinks pinned true).
# FAIL CLOSED (non-zero, empty stdout, message on stderr naming the path): see the table. text/eol attributes still normalise line endings the
# way a commit would (an edit that only flips CRLF/LF of such a file shows no change, as it would not in a commit).
# WHY fail closed: output is written only after every stage succeeded (built in a temp file, emitted last), so a failed stage leaves stdout empty
# and the exit nonzero; an empty hash input must never look like a valid snapshot. `set -e` is not used because each status is checked explicitly.
# WHY every output-shaping setting is pinned HERE and nowhere else (r29): the hash is only evidence if the same state always yields the same
# bytes. A configured diff.external or textconv driver could omit or normalise a change, and diff.noprefix, diff.mnemonicPrefix, color.ui,
# diff.context, core.abbrev, diff.renames, diff.algorithm, diff.relative, core.quotePath, autocrlf or GIT_EXTERNAL_DIFF/GIT_DIFF_OPTS in the
# environment would change the bytes. Command-line -c and flags outrank repo, user and system config, so nothing a user configures can reach
# the output. Renames are OFF on purpose: rename detection depends on similarity heuristics and diff.renames, so the reviewer sees a plain
# delete plus add, which is always complete. core.quotePath=true (the default) makes non-ASCII names print as ASCII octal escapes.
# WHY index.maxPathLen is pinned (git 2.56 key, cc11 r42): a repo config can shrink it, and then update-index skips every longer path with only an
# "Ignoring path" line on stderr and exit 0, so the reviewed diff silently omits those files. 1073740799 is git's own default; older git ignores the key.
# Removing the pin reopens that hole on git >= 2.56 (tests/check-snapshot-config-keys.py flags it there; git 2.43 cannot).
# WHY the three --output-indicator flags (r33): they change the +, - and space that start every hunk line, and the redactor (redact-diff.sh) reads that first byte as the side of the line. A removed private-key END
# line printed with another prefix looked like context there and exposed the replacement key body. Git 2.43 has no config key for them (flags only, see tests/check-snapshot-config-keys.py, which would flag one
# on a newer git); they are pinned anyway so no caller path, alias-free or not, can change them, and the redactor now also fails closed on any hunk line it cannot place.
# Settings that CAN still change the bytes, because they live in the repo itself: .gitattributes `-diff`/`binary` and `diff=<driver>` with
# `diff.<driver>.binary` (they flip a file to "Binary files differ"; --full-index keeps the blob ids in the output, so an edit still changes the
# bytes). Filters are not in this list: they fail closed, see above.
set -o pipefail
export LC_ALL=C
# BEGIN git-env-clean (the same text sits in scripts/review-snapshot.sh and scripts/codex-call.sh; tests/test-mirrors.py fails when the two differ)
# WHY (cc11 r64): an inherited GIT_* variable can change what a path, a repository, an index, an object store or a config key MEANS (GIT_LITERAL_PATHSPECS=1
# made the snapshot's `:(top)` and exclude pathspecs plain file names, so a changed tree printed an empty snapshot with exit 0). Clearing one variable at a
# time was tried first and each review found another, so the whole class is cleared here. Config files are pinned to /dev/null instead of unset, so the
# user's own ~/.gitconfig cannot change the bytes either. Removing a name reopens that hole; tests/check-snapshot-hermetic.py sets each one in turn.
clean_git_env() {
  local v
  unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX GIT_INDEX_FILE \
        GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_PAGER GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_NAMESPACE GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_ATTR_SOURCE GIT_REPLACE_REF_BASE GIT_NO_REPLACE_OBJECTS
  for v in $(compgen -e); do case "$v" in GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset "$v" ;; esac; done
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1
}
# END git-env-clean
clean_git_env
CFG=(-c core.quotePath=true -c core.fileMode=true -c core.symlinks=true -c core.ignoreCase=false -c core.fsmonitor=false
     -c core.untrackedCache=false -c core.splitIndex=false -c core.sparseCheckout=false -c core.excludesFile=/dev/null -c index.sparse=false -c index.maxPathLen=1073740799 -c core.autocrlf=false -c core.safecrlf=false -c core.attributesFile=/dev/null -c core.abbrev=auto -c core.bigFileThreshold=512m -c core.ignoreStat=false
     -c diff.external= -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.renames=false -c diff.algorithm=myers
     -c diff.indentHeuristic=true -c diff.context=3 -c diff.interHunkContext=0 -c diff.relative=false -c diff.submodule=short
     -c diff.ignoreSubmodules=none -c diff.wsErrorHighlight=none -c diff.colorMoved=false -c diff.suppressBlankEmpty=false
     -c color.ui=never -c color.diff=never)
DOPT=(--no-ext-diff --no-textconv --no-color --no-color-moved --no-renames --no-relative --src-prefix=a/ --dst-prefix=b/ --full-index
      --diff-algorithm=myers --indent-heuristic -U3 --inter-hunk-context=0 --ignore-submodules=none --submodule=short -O/dev/null
      --output-indicator-new=+ --output-indicator-old=- --output-indicator-context=' ')
canon() { git "${CFG[@]}" "$@"; }
# WHY the script's own absolute path is resolved HERE, before any cd (r31): snapshot mode changes to the repo root, and a relative $0 (started from a
# subdirectory) or a bare name (found through PATH) no longer names the script afterwards, so the recursive submodule call broke. A symlinked install
# (the skills put it under ~/.claude/config/scripts) is kept as the symlink path, which is what the recursive call needs. The recursion starts it with
# bash explicitly so it never depends on the exec bit.
self="$0"
case "$self" in */*) ;; *) self="$(command -v -- "$self" 2>/dev/null)" || self="$0" ;; esac
self_dir="$(cd -- "$(dirname -- "$self")" 2>/dev/null && pwd)" || self_dir=""
self="$self_dir/$(basename -- "$self")"
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
    die() { echo "review-snapshot: $*" >&2; exit 1; }
    base_tree="$(canon rev-parse --verify "$base^{tree}")" || die "cannot resolve $base"
    real_obj="$(canon rev-parse --path-format=absolute --git-path objects)" || exit 1
    case "$real_obj" in *:*) die "object directory path contains a colon" ;; esac
    # What the user's index may tell us (content-addressed facts only, never stat data): its entries (mode + blob id + stage), which paths are
    # skip-worktree, which are gitlinks. These are read BEFORE the private index is exported.
    canon ls-files -z -s > "$tmp/idx-entries" || exit 1
    canon ls-files -z --cached > "$tmp/idx-paths" || exit 1
    canon ls-files -z -t | while IFS= read -r -d '' rec; do case "$rec" in "S "*) printf '%s\0' "${rec#S }" ;; esac; done > "$tmp/skipwt"
    [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
    : > "$tmp/gitlinks"
    while IFS= read -r -d '' rec; do
      meta="${rec%%$'\t'*}"
      [ "${meta##* }" = 0 ] || die "${rec#*$'\t'} has an unmerged index entry: resolve the conflict first"
      case "$meta" in 160000\ *) printf '%s\0' "${rec#*$'\t'}" >> "$tmp/gitlinks" ;; esac
    done < "$tmp/idx-entries"
    canon ls-tree -r -z --name-only "$base_tree" > "$tmp/base-paths" || exit 1
    # Everything on disk that is not ignored, found with an EMPTY index so nothing tracked is skipped (nested repos come out as "dir/").
    GIT_INDEX_FILE="$tmp/none" canon ls-files --others --exclude-standard -z > "$tmp/others" || exit 1
    cat "$tmp/others" "$tmp/base-paths" "$tmp/idx-paths" | sort -z -u > "$tmp/cands" || exit 1
    # Fresh private index and object directory: the user's index and object store are neither read for content nor written.
    mkdir -p "$tmp/objects/info" "$tmp/objects/pack" || exit 1
    export GIT_INDEX_FILE="$tmp/index" GIT_OBJECT_DIRECTORY="$tmp/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$real_obj"
    # The private index starts from the CURRENT entries, NOT the base (r31): the base is only the left side of the final diff.
    canon update-index -z --index-info < "$tmp/idx-entries" || exit 1
    : > "$tmp/upd"; : > "$tmp/rm"; : > "$tmp/info"; : > "$tmp/dirs-done"
    while IFS= read -r -d '' p; do
      p="${p%/}"
      case "$p" in *$'\n'*) die "a path contains a newline: refusing" ;; esac
      if [ -L "$p" ]; then printf '%s\0' "$p" >> "$tmp/upd"
      elif [ -d "$p" ]; then
        grep -qzxF -- "$p" "$tmp/dirs-done" && continue
        printf '%s\0' "$p" >> "$tmp/dirs-done"
        if grep -qzxF -- "$p" "$tmp/gitlinks"; then
          [ -e "$p/.git" ] || continue   # an uninitialized submodule directory: the CURRENT index gitlink stays (a moved pointer shows as the change)
          sub_out="$(cd -- "./$p" && env -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES "${BASH:-bash}" "$self" HEAD)" || die "submodule $p: its own snapshot failed"
          [ -z "$sub_out" ] || die "submodule $p has uncommitted or untracked changes"
          sub_sha="$(canon -C "$p" rev-parse --verify HEAD)" || die "submodule $p has no HEAD"
          printf '160000 %s\t%s\0' "$sub_sha" "$p" >> "$tmp/info"
        elif [ -e "$p/.git" ]; then die "$p is a nested git repository the snapshot cannot bind"
        else printf '%s\0' "$p" >> "$tmp/rm"   # a plain directory where the index had a file
        fi
      elif [ -f "$p" ]; then printf '%s\0' "$p" >> "$tmp/upd"
      elif [ -e "$p" ]; then die "$p is not a regular file, symlink or directory"
      else
        grep -qzxF -- "$p" "$tmp/skipwt" && continue   # absent by design (sparse checkout): the CURRENT index entry (mode + blob id) stays, never a deletion
        printf '%s\0' "$p" >> "$tmp/rm"
      fi
    done < "$tmp/cands"
    # Content hashing would run clean filters, ident or re-encoding on file bytes, which are user code or a rewrite git cannot undo: fail closed.
    if [ -s "$tmp/upd" ]; then
      canon check-attr -z --stdin filter ident working-tree-encoding < "$tmp/upd" > "$tmp/attrs" || exit 1
      bad="$(tr '\0' '\n' < "$tmp/attrs" | awk 'NR%3==1{p=$0} NR%3==0 && $0!="unspecified" && $0!="unset"{print p; exit}')"
      [ -z "$bad" ] || die "$bad has a filter, ident or working-tree-encoding attribute: its bytes cannot be bound canonically"
    fi
    [ ! -s "$tmp/rm" ] || canon update-index --force-remove -z --stdin < "$tmp/rm" || exit 1
    [ ! -s "$tmp/upd" ] || canon update-index --add --replace -z --stdin < "$tmp/upd" || exit 1
    [ ! -s "$tmp/info" ] || canon update-index --add --replace -z --index-info < "$tmp/info" || exit 1
    new_tree="$(canon write-tree)" || exit 1
    canon diff "${DOPT[@]}" "$base_tree" "$new_tree" -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' ':(top,exclude).claude/review' ':(top,exclude).claude/plan' > "$tmp/out" || exit 1
    # WHY an empty snapshot is cross-checked (cc11 r64): the pathspec above is the only thing standing between "nothing changed" and "everything was filtered out", and
    # an empty result looks exactly like a clean tree. The same two trees are listed WITHOUT any pathspec and every name is run through the exclusion rules again in
    # plain bash; a name that survives them while the snapshot is empty means the filtering lied, so fail closed instead of printing nothing with exit 0.
    if [ ! -s "$tmp/out" ]; then
      canon diff --name-only -z "$base_tree" "$new_tree" > "$tmp/names" || exit 1
      while IFS= read -r -d '' p; do
        keep=1; oldifs="$IFS"; IFS=/
        # shellcheck disable=SC2086
        set -- $p; IFS="$oldifs"
        case "$p" in .claude/review|.claude/review/*|.claude/plan|.claude/plan/*) keep=0 ;; esac
        for part in "$@"; do
          lc="$(printf '%s' "$part" | tr 'A-Z' 'a-z')"
          case "$lc" in .env*|*secret*|*credential*|*.pem|*.key) keep=0 ;; esac
        done
        [ "$keep" = 1 ] && die "the snapshot is empty but $p differs from the base: the path filtering dropped a real change"
      done < "$tmp/names"
    fi ;;
esac
cat "$tmp/out" || exit 1
