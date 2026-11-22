---
name: codex-mcp
description: How to call OpenAI Codex (plan audits, code review, implementation) via codex-call.sh, the codex exec wrapper that replaced the removed Codex MCP server. Use when calling Codex for implementation, review or any cross-model collaboration.
---

# Codex Usage Guide (codex exec wrapper)

`codex mcp-server` was deprecated by OpenAI on 2026-08-24 and removed in Codex CLI 0.154.0, so the `mcp__codex__codex` and `mcp__codex__codex-reply` tools no longer exist. `codex exec` is the supported non-interactive interface. All skills call it through one wrapper.

## Tool

`~/.claude/config/scripts/codex-call.sh [--sandbox MODE] [--role FILE] [--resume THREAD_ID] [--cd DIR] PROMPT`

Run it with Bash. Output: first line `THREAD_ID: <id>`, then Codex's final message. It exits non-zero with "UNREVIEWED" when Codex returns no message: that is never an approval.

## Session Management

Sessions are stateful via the thread id. Always:
1. Save `THREAD_ID` from the first call
2. Pass `--resume THREAD_ID` for all follow-ups, with the same `--sandbox` and `--cd` as the first call (the wrapper applies them and the review profile to the resumed turn; `--sandbox` defaults to `read-only`)
3. Never start a new session when continuing the same task

## Key Parameters

### --sandbox
| Mode | When to Use |
|------|-------------|
| `read-only` (default) | Plan review, code audit, Q&A: Codex reads but cannot write files |
| `workspace-write` | Implementation: Codex writes files in the project directory |

Approval is always `never` (set in the review profile); commands run inside the sandbox without prompting.

### --role FILE
Prepends a persona or constraints file to the prompt. Use the absolute installed path (for example `~/.claude/skills/plan-codex/codex-analyzer-role.md`): a bare filename is read relative to the project directory and will not be found. Add "Be concise. Output result only, no reasoning process." to the prompt itself.

### Model
Set once in `~/.codex/review.config.toml` (the `review` profile). Never pass `-m` anywhere.

## Prompting Best Practices

1. **Termination signals**: Ask Codex for a structured verdict with optional severity lines; the loop exits only on a round whose reply is exactly `VERDICT: APPROVED` with zero findings at any severity, or whose every finding was dropped through discussion. A `VERDICT: BLOCKED` or `VERDICT: WARNING` reply that lists no finding is not clean and not actionable: send ONE follow-up asking it to list its findings, and treat a repeat that still lists none as no verdict
2. **Feedback verbatim**: When sending review feedback via `--resume`, quote specific issues exactly. Do not summarize.
3. **Concise responses**: Always instruct Codex to be concise to save tokens
4. **No iteration cap**: Review loops have no round cap and no severity floor. Round 6, 10 or 20 continues the same way while accepted findings remain, and a round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed like a CRITICAL one. Preferences and false positives end through discussion with the active reviewer (via `--resume` when Codex is the reviewer; only an authorized reviewer's recorded concession drops a finding), never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Fallback input paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do A reviewer that asks for the same kind of thing every round (for example the tracking marker a repo rule such as REVIEW.md requires) is not looping or unsatisfiable: satisfy what it cites and re-review. Never conclude the reviewer is stuck, never report that no clean round was reached and never hand the user a keep-going-or-drop-it decision; a doubt about a finding is raised with the active reviewer (in the same Codex thread when Codex is the reviewer), and the only other exit is the failed-review rule. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict.

**Fallback input (tier S)**: the fallback reviewer sees only the one file you hand it, so every tier S call uses ONE context file, built exactly as below and never a bare diff. It carries what the Codex call carried: the sanitized task requirements (the task or plan text, every task of a multi-task run, with any secret, credential or `.env` value removed), the review or audit instructions you sent to Codex (for a test audit, its Evaluate list), every carried finding (raised in an earlier round and still open) and every contested finding with your reasoning, then the sanitized diff, made after the same intent-to-add step for the files this task created as the Codex call. Rebuild the file for every round so it holds the CURRENT diff and the current findings. The diff goes through `~/.claude/config/scripts/redact-diff.sh` before it is appended: that script is a best-effort mask of inline credential values (private key blocks, cloud and API tokens, Bearer tokens, JWTs, password and secret assignments) on top of the path exclusions, not a guarantee, and the paths stay excluded. If the script is missing or exits non-zero the context file is deleted and no context is sent, so there is no verdict from the fallback and the work stays unreviewed.

```
CTX="$(mktemp)"
cat > "$CTX" <<'EOF'
TASK REQUIREMENTS:
<the sanitized task requirements>

REVIEW INSTRUCTIONS:
<the review or audit instructions sent to Codex>

OPEN FINDINGS:
<every carried and contested finding with your reasoning, or the word none>

DIFF:
EOF
(set -o pipefail; git diff HEAD -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' | ~/.claude/config/scripts/redact-diff.sh >> "$CTX") || { rm -f "$CTX"; echo "redaction failed: no context is sent"; }
[ -f "$CTX" ] && ~/.claude/config/scripts/reviewer.sh S "$CTX" <out-file>
```

