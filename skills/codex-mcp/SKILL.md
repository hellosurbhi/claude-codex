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
2. Pass `--resume THREAD_ID` for all follow-ups (resume keeps the original sandbox and cwd)
3. Never start a new session when continuing the same task

## Key Parameters

### --sandbox
| Mode | When to Use |
|------|-------------|
| `read-only` (default) | Plan review, code audit, Q&A: Codex reads but cannot write files |
| `workspace-write` | Implementation: Codex writes files in the project directory |

Approval is always `never` (set in the review profile); commands run inside the sandbox without prompting.

### --role FILE
Prepends a persona or constraints file to the prompt (for example `codex-analyzer-role.md`). Add "Be concise. Output result only, no reasoning process." to the prompt itself.

### Model
Set once in `~/.codex/review.config.toml` (the `review` profile). Never pass `-m` anywhere.

## Prompting Best Practices

1. **Termination signals**: Ask Codex to reply "APPROVED" or "CHANGES NEEDED" so the loop has a clear exit
2. **Feedback verbatim**: When sending review feedback via `--resume`, quote specific issues exactly. Do not summarize.
3. **Concise responses**: Always instruct Codex to be concise to save tokens
4. **Max iterations**: Always enforce a hard cap (default: 5) on review loops
