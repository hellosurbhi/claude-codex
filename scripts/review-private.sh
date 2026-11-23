#!/usr/bin/env bash
# contract: review-private v1 (source of truth: hellosurbhi/claude-codex scripts/review-private.sh)
# Usage: review-private.sh init                              create <repo top>/.claude/review private (umask 077, mode 700). Exit 0 only when it exists with mode 700.
#        review-private.sh clean                             delete the raw (unredacted) files a review leaves under <repo top>/.claude/review. Fixed names only.
#        review-private.sh plan-fallback <feature> <out-file> build the tier S plan-audit context from .claude/review/audit-notes.raw.txt plus .claude/plan/<feature>.md,
#                                                            run reviewer.sh S on it, delete the notes and the context on every exit path. Exit = reviewer.sh's exit.
# WHY this script exists (cc11 r64 finding 2): plan-codex's confined run may only run single prescribed commands, and the skill used to tell the model to type an inline
# `umask 077; mkdir; chmod`, and a subshell with EXIT and HUP/INT/TERM traps, which the confinement hook (rightly) denies. The private-folder setup and the trap-and-delete
# fallback block now live here as FIXED subcommands, so the hook allows exactly this script with exactly these subcommands and no free-form shell. Changing a subcommand's
# behavior means re-checking tests/proof-confine-hook.py (check_wrapper) and the plan-codex walk in tests/test-checkers.sh.
set -u
# BEGIN git-env-clean (the same text sits in every script that calls git: review-snapshot.sh, codex-call.sh, review-private.sh; tests/test-mirrors.py fails when they differ)
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
usage() { echo "usage: review-private.sh init | clean | plan-fallback <feature-name> <out-file>" >&2; exit 2; }
[ $# -ge 1 ] || usage
sub="$1"; shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
R="$(clean_git_env; git rev-parse --show-toplevel 2>/dev/null)" || R=""
[ -n "$R" ] || { echo "review-private: not inside a git repository" >&2; exit 1; }
rv="$R/.claude/review"
case "$sub" in
  init)
    [ $# -eq 0 ] || usage
    (umask 077; mkdir -p "$rv" && chmod 700 "$rv") || exit 1 ;;
  clean)
    [ $# -eq 0 ] || usage
    # WHY a fixed list and not a glob: this must never delete anything a person put there, only the files the skills write.
    rm -f "$rv/requirements.raw.txt" "$rv/reply.raw.txt" "$rv/audit-notes.raw.txt" "$rv/prompt.raw.txt" "$rv/reviewed.diff" || exit 1 ;;
  plan-fallback)
    [ $# -eq 2 ] || usage
    feature="$1"; out="$2"
    # WHY the name check: <feature> becomes a path component under .claude/plan, so a slash, a leading dash or a dot-only name must not get through.
    case "$feature" in ""|-*|*/*|.|..) echo "review-private: bad feature name" >&2; exit 2 ;; esac
    case "$feature" in *[!A-Za-z0-9._-]*) echo "review-private: bad feature name" >&2; exit 2 ;; esac
    umask 077
    notes="$rv/audit-notes.raw.txt"; plan="$R/.claude/plan/$feature.md"
    ctx="$(mktemp "${TMPDIR:-/tmp}/review-ctx.XXXXXX")" || { rm -f "$notes"; exit 1; }
    # WHY the traps are set before anything reads the notes (r55): the raw notes and the context are deleted on success, on any failure and on an interrupt, and a
    # leftover copy from an earlier attempt is never reused. `trap 'exit 1' HUP INT TERM` turns a signal into an exit so the EXIT trap runs.
    trap 'rm -f "$notes" "$ctx"' EXIT; trap 'exit 1' HUP INT TERM
    if [ -s "$notes" ] && [ -s "$plan" ] && cat "$notes" > "$ctx" && printf '\nPLAN:\n' >> "$ctx" && cat "$plan" >> "$ctx"
    then "$here/reviewer.sh" S "$ctx" "$out"; exit $?
    else echo "the audit notes file or the plan file is missing, empty or unreadable: no context is sent"; exit 1; fi ;;
  *) usage ;;
esac
