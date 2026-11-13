#!/usr/bin/env bash
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
#   codex-call.sh [--sandbox read-only|workspace-write] [--role FILE] [--resume THREAD_ID] [--cd DIR] PROMPT
# Output (stdout): first line `THREAD_ID: <id>`, then Codex's final message.
# Exit non-zero if Codex fails or returns no message: a dead call is NOT an approval.
set -euo pipefail
command -v python3 >/dev/null || { echo "codex-call: python3 is required (it parses the Codex event stream). Treat as UNREVIEWED." >&2; exit 2; }
sandbox=read-only role="" resume="" dir="$PWD"
while [[ $# -gt 1 ]]; do
  case "$1" in
    --sandbox) sandbox="$2"; shift 2 ;;
    --role) role="$2"; shift 2 ;;
    --resume) resume="$2"; shift 2 ;;
    --cd) dir="$2"; shift 2 ;;
    *) break ;;
  esac
done
prompt="$1"
[[ -n "$role" ]] && prompt="$(cat "$role")"$'\n\n'"$prompt"
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
if [[ -n "$resume" ]]; then
  # WHY the profile, sandbox and cwd go BEFORE `resume`: the resume subcommand has no
  # -p/-s/-C flags of its own, and relying on the stored thread settings left a
  # continued audit without an explicit review profile or read-only policy
  # (codex306-r1). Verified 2026-11-12 on CLI 0.167.1: the resumed turn's
  # turn_context reads gpt-6.1-sol, xhigh, read-only.
  codex exec -p review --sandbox "$sandbox" --cd "$dir" resume --json --skip-git-repo-check "$resume" "$prompt" </dev/null >"$out" 2>&1 && rc=0 || rc=$?
else
  # --skip-git-repo-check: plan audits can run from a scratch folder that is not a repo
  codex exec --json -p review --sandbox "$sandbox" --skip-git-repo-check --cd "$dir" "$prompt" </dev/null >"$out" 2>&1 && rc=0 || rc=$?
fi
python3 - "$out" "$rc" <<'PY'
import json, sys
tid, msg, done, errs = "", "", False, []
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("type") == "thread.started": tid = e["thread_id"]
    if e.get("type") == "turn.completed": done = True
    if e.get("type") == "turn.failed":
        done = False
        errs.append((e.get("error") or {}).get("message", ""))
    if e.get("type") == "error": errs.append(e.get("message", ""))
    it = e.get("item", {})
    if e.get("type") == "item.completed" and it.get("type") == "agent_message": msg = it["text"]
# WHY require turn.completed AND exit 0: a nonzero exit after turn.completed is still a failed call.
# WHY require turn.completed: a dropped connection mid-run leaves an earlier progress
# message ("I'll read the plan...") as the last agent_message; returning that would
# look like a verdict-less answer instead of a dead call.
if not msg or not done or sys.argv[2] != "0":
    # WHY print the CLI's own non-JSON lines: auth, profile and quota errors arrive
    # there, and the scratch file is deleted on exit, so this is the only copy.
    # Quota errors (with their reset time) arrive as JSON error events, not plain text.
    diag = [m for m in errs if m] + [l.rstrip() for l in open(sys.argv[1]) if not l.lstrip().startswith("{")][-20:]
    if diag: print("codex-call: Codex CLI said:\n" + "\n".join(diag), file=sys.stderr)
    sys.exit("codex-call: Codex turn did not complete (call died). Treat as UNREVIEWED.")
print(f"THREAD_ID: {tid}\n{msg}")
PY
