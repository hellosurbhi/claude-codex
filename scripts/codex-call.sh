#!/usr/bin/env bash
# contract: codex-call v3 (source of truth: hellosurbhi/claude-codex scripts/codex-call.sh)
# codex-call.sh: one Codex turn via `codex exec` (the supported replacement for the removed
# `codex mcp-server` tools mcp__codex__codex / mcp__codex__codex-reply).
#
# WHY: Codex CLI 0.154.0 removed `codex mcp-server`; OpenAI's stable non-interactive
# interface is `codex exec` (resumable by thread id). Model and effort come from the
# `review` profile (~/.codex/review.config.toml), set in exactly one place.
#
# Shipped here so the skills work from a plain clone of this repo; README step 3
# installs it at ~/.claude/config/scripts/codex-call.sh, the path every skill calls.
#
# Usage:
#   codex-call.sh [--sandbox read-only|workspace-write] [--role FILE] [--resume THREAD_ID] [--cd DIR] (--prompt-file FILE | [--] PROMPT)
# Strict: each option needs its value; an unknown option or an extra argument exits 2 with the usage line; put a prompt that starts with a dash after `--`.
# The prompt always reaches Codex on stdin (`-`), never as a process argument. Use --prompt-file for anything that can be large (a diff):
# a positional PROMPT is still accepted for short text, but it is limited by the OS argument size, a prompt file is not.
# Output (stdout): first line `THREAD_ID: <id>`, then Codex's final message.
# Exit non-zero if Codex fails or returns no message: a dead call is NOT an approval.
set -euo pipefail
command -v python3 >/dev/null || { echo "codex-call: python3 is required (it parses the Codex event stream). Treat as UNREVIEWED." >&2; exit 2; }
# WHY the repository top and not $PWD (cc11-main-r2 finding 3): Codex reviews relative to --cd, so a review started from a subfolder saw only that folder.
sandbox=read-only role="" resume="" resume_set=0 pfile="" pfile_set=0 dir="$(git rev-parse --show-toplevel 2>/dev/null || printf "%s" "$PWD")"
# WHY the parser is strict (r22 finding 3): the old loop only ran while two arguments remained, so a lone `--resume` skipped parsing and became the PROMPT, an unknown option was sent to Codex as prompt text
# and extra positional arguments were silently dropped. Every option needs a value that is not itself option-like, an unknown option or an extra argument exits 2 with the usage line, and `--` ends the options so
# a prompt that starts with a dash is still possible. Do not relax this back to "anything unrecognised is the prompt".
usage="usage: codex-call.sh [--sandbox read-only|workspace-write] [--role FILE] [--resume THREAD_ID] [--cd DIR] (--prompt-file FILE | [--] PROMPT)"
die_usage() { echo "codex-call: $1. $usage. No call was made; treat as UNREVIEWED." >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox|--role|--resume|--cd|--prompt-file)
      [[ $# -ge 2 ]] || die_usage "option $1 needs a value"
      [[ "$2" != -* ]] || die_usage "option $1 needs a value, not the option-like $2"
      case "$1" in
        --sandbox) sandbox="$2" ;;
        --role) role="$2" ;;
        --resume) resume="$2"; resume_set=1 ;;
        --cd) dir="$2" ;;
        --prompt-file) pfile="$2"; pfile_set=1 ;;
      esac
      shift 2 ;;
    --) shift; break ;;
    -*) die_usage "unknown option $1 (put a prompt that starts with a dash after --)" ;;
    *) break ;;
  esac
done
# WHY an explicitly empty --resume is an error and not "start a new session" (r19 finding 2): a caller that lost its thread id would silently open a fresh session and the continued review
# would run without the context it relied on. "Not passed" (resume_set=0) is still a new session; "passed but empty" never reaches codex.
if [[ $resume_set -eq 1 && -z "$resume" ]]; then echo "codex-call: empty --resume value (a thread id was expected). Treat as UNREVIEWED." >&2; exit 2; fi
# WHY the prompt goes on stdin from a file (r20 finding 1): a whole diff as one argument exceeds the OS argument limit (E2BIG) and Codex never started. Verified on the installed CLI:
# `codex exec [PROMPT]` and `codex exec resume [ID] [PROMPT]` both read the instructions from stdin when the prompt is `-`. A positional PROMPT is written to the same file, so there is one path.
# WHY a missing or empty prompt file is an error and never an empty review: Codex would answer an empty prompt with something that looks like a verdict.
if [[ $pfile_set -eq 1 ]]; then
  if [[ $# -gt 0 ]]; then echo "codex-call: give either --prompt-file or a positional prompt, not both. Treat as UNREVIEWED." >&2; exit 2; fi
  if [[ -z "$pfile" || ! -s "$pfile" ]]; then echo "codex-call: prompt file is missing or empty: ${pfile:-<empty name>}. No call was made; treat as UNREVIEWED." >&2; exit 2; fi
elif [[ $# -lt 1 ]]; then die_usage "no prompt (pass --prompt-file FILE or a prompt)"
elif [[ $# -gt 1 ]]; then die_usage "unexpected extra arguments after the prompt ($# given, one expected)"; fi
# WHY every step below checks its own status (r21 finding 2): `A && B` and a command substitution inside printf do not trip `set -e` when A (or the inner cat) fails, so a missing role file used to
# send the prompt WITHOUT its role text, and a failed temp-file write used to go on. Each step now stops with a message and exit 2, before anything is sent.
if [[ -n "$role" ]]; then
  if [[ ! -f "$role" || ! -r "$role" || ! -s "$role" ]]; then echo "codex-call: role file is missing, unreadable or empty: $role. No call was made; treat as UNREVIEWED." >&2; exit 2; fi
  role_text="$(cat "$role")" || { echo "codex-call: could not read the role file: $role. No call was made; treat as UNREVIEWED." >&2; exit 2; }
  [[ -n "$role_text" ]] || { echo "codex-call: role file has no text: $role. No call was made; treat as UNREVIEWED." >&2; exit 2; }
fi
# WHY cleanup names only non-empty paths (r22 finding 2): the trap is installed before the temp files exist, and an unset $pin made "$pin.role" expand to ".role", deleting a file of that name in the working directory
# when a mktemp failed. Do not collapse this back into one `rm -f "$out" "$pin" "$pin.role"`.
out=""; pin=""
cleanup() { [[ -z "$out" ]] || rm -f -- "$out"; if [[ -n "$pin" ]]; then rm -f -- "$pin" "$pin.role"; fi; }
trap cleanup EXIT
out="$(mktemp)" || { echo "codex-call: could not create a temp file (is TMPDIR writable?). No call was made; treat as UNREVIEWED." >&2; exit 2; }
pin="$(mktemp)" || { echo "codex-call: could not create a temp file (is TMPDIR writable?). No call was made; treat as UNREVIEWED." >&2; exit 2; }
if [[ $pfile_set -eq 1 ]]; then
  cp "$pfile" "$pin" || { echo "codex-call: could not read the prompt file: $pfile. No call was made; treat as UNREVIEWED." >&2; exit 2; }
else
  printf '%s' "$1" > "$pin" || { echo "codex-call: could not write the prompt to a temp file. No call was made; treat as UNREVIEWED." >&2; exit 2; }
fi
[[ -s "$pin" ]] || { echo "codex-call: the prompt is empty after reading it. No call was made; treat as UNREVIEWED." >&2; exit 2; }
if [[ -n "$role" ]]; then
  { printf '%s\n\n' "$role_text" && cat "$pin"; } > "$pin.role" || { echo "codex-call: could not build the prompt with the role text. No call was made; treat as UNREVIEWED." >&2; exit 2; }
  mv "$pin.role" "$pin" || { echo "codex-call: could not build the prompt with the role text. No call was made; treat as UNREVIEWED." >&2; exit 2; }
fi
if [[ $resume_set -eq 1 ]]; then
  # WHY the profile, sandbox and cwd go BEFORE `resume`: the resume subcommand has no
  # -p/-s/-C flags of its own, and relying on the stored thread settings left a
  # continued audit without an explicit review profile or read-only policy
  # (codex306-r1). Verified 2026-11-12 on CLI 0.167.1: the resumed turn's
  # turn_context reads gpt-6.1-sol, xhigh, read-only.
  codex exec -p review --sandbox "$sandbox" --cd "$dir" resume --json --skip-git-repo-check "$resume" - <"$pin" >"$out" 2>&1 && rc=0 || rc=$?
else
  # --skip-git-repo-check: plan audits can run from a scratch folder that is not a repo
  codex exec --json -p review --sandbox "$sandbox" --skip-git-repo-check --cd "$dir" - <"$pin" >"$out" 2>&1 && rc=0 || rc=$?
fi
python3 - "$out" "$rc" <<'PY'
import json, sys
tid, msg, done, errs = "", "", False, []
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("type") == "thread.started": tid = str(e.get("thread_id") or "")
    if e.get("type") == "turn.completed": done = True
    if e.get("type") == "turn.failed":
        done = False
        errs.append(str((e.get("error") or {}).get("message", e)))
    if e.get("type") == "error": errs.append(str(e.get("message", e)))
    it = e.get("item", {})
    if e.get("type") == "item.completed" and it.get("type") == "agent_message": msg = it["text"]
# WHY require turn.completed AND exit 0: a nonzero exit after turn.completed is still a failed call.
# WHY require turn.completed: a dropped connection mid-run leaves an earlier progress
# message ("I'll read the plan...") as the last agent_message; returning that would
# look like a verdict-less answer instead of a dead call.
# WHY a completed turn with no thread id is a failed call (r19 finding 2): the caller would print an empty THREAD_ID, and a later resume with it would start a new session and lose the review context.
if msg and done and sys.argv[2] == "0" and not tid:
    sys.exit("codex-call: Codex completed the turn but reported no thread id, so the review cannot be resumed. Treat as UNREVIEWED (no verdict).")
if not msg or not done or sys.argv[2] != "0":
    # WHY print the CLI's own non-JSON lines: auth, profile and quota errors arrive
    # there, and the scratch file is deleted on exit, so this is the only copy.
    # Quota errors (with their reset time) arrive as JSON error events, not plain text. An event with no message is printed whole (str(e)),
    # never as an empty line, so a bare usage_limit code still reaches the caller (error-handling expressions taken from Global Config PR 306).
    diag = [m for m in errs if m] + [l.rstrip() for l in open(sys.argv[1]) if not l.lstrip().startswith("{")][-20:]
    if diag: print("codex-call: Codex CLI said:\n" + "\n".join(diag), file=sys.stderr)
    sys.exit("codex-call: Codex turn did not complete (call died). Treat as UNREVIEWED.")
print(f"THREAD_ID: {tid}\n{msg}")
PY
