---
name: codex-mcp
description: How to call OpenAI Codex (plan audits, code review, implementation) via codex-call.sh, the codex exec wrapper that replaced the removed Codex MCP server. Use when calling Codex for implementation, review, or any cross-model collaboration.
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

1. **Termination signals**: Ask Codex for a structured verdict with severity lines; the loop exits only on a round with no accepted findings at any severity
2. **Feedback verbatim**: When sending review feedback via `--resume`, quote specific issues exactly. Do not summarize.
3. **Concise responses**: Always instruct Codex to be concise to save tokens
4. **No iteration cap**: Review loops have no round cap and no severity floor. Round 6, 10 or 20 continues the same way while accepted findings remain, and a round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed like a CRITICAL one. Preferences and false positives end through discussion via `--resume` (only an explicit reviewer concession drops a finding), never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`; the CodeRabbit CLI has no thread and takes no prompt, so each follow-up is a fresh review of the new committed state, and a finding you contest is settled only by a Codex reviewer's explicit concession. Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do
