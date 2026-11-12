# Codex Reference: Detailed Patterns (codex-call.sh)

All calls run through `~/.claude/config/scripts/codex-call.sh` with Bash. The removed `codex mcp-server` tools are not used anywhere.

## Starting a Review Session

```bash
~/.claude/config/scripts/codex-call.sh --sandbox read-only --cd "$PWD" \
  --role ~/.claude/skills/plan-codex/codex-analyzer-role.md \
  "Review the plan at .claude/plan/<feature>.md for correctness, completeness,
security and edge cases. Reply APPROVED if solid, or list specific issues to fix.
Be concise. Output result only, no reasoning process."
```

Save the `THREAD_ID:` value from the first output line.

## Starting an Implementation Session

```bash
~/.claude/config/scripts/codex-call.sh --sandbox workspace-write --cd "$PWD" \
  --role ~/.claude/skills/execute-codex/codex-architect-role.md \
  "Implement the following task. Write production-quality code.
Follow existing project conventions. Do not modify unrelated files.
Be concise. Output result only, no reasoning process.

<task description or plan content>"
```

## Continuing with Feedback

```bash
~/.claude/config/scripts/codex-call.sh --resume "$THREAD_ID" --sandbox workspace-write --cd "$PWD" \
  "Fix these issues from code review:
- auth.ts:42: missing null check on user.email
- api.ts:15: no rate limiting on /login endpoint
Reimplement with these fixes."
```

Pass the same `--sandbox` and `--cd` as the first call: the wrapper applies them (and the `review` profile) to the resumed turn, and `--sandbox` defaults to `read-only`.

## Loop Termination Signals

| Loop Type | Termination Signal | Who Decides |
|-----------|-------------------|-------------|
| Plan review | A Codex round lists no accepted findings at any severity | Codex verdict plus Claude's evaluation gate |
| Execute review | A reviewer round lists no accepted findings at any severity | Reviewer plus Claude's evaluation gate |

There is no iteration cap and no severity floor: keep fixing and re-reviewing while any accepted CRITICAL, HIGH, MEDIUM or LOW finding remains, in round 6 and beyond. Disputed findings are settled through discussion with `--resume`, never by stopping after N rounds. A review that errors, times out or returns no verdict is retried once; if it fails again, report the work as UNREVIEWED.

## Anti-Patterns

- **Don't start new sessions per iteration**: wastes context and loses conversation history; use `--resume`
- **Don't summarize reviewer feedback**: Codex needs exact file:line references to fix issues
- **Don't use `danger-full-access`**: `workspace-write` is sufficient for implementation
- **Don't skip `--role`**: the role file shapes response quality significantly
- **Don't omit the conciseness instruction**: Codex may include lengthy reasoning that wastes context tokens
- **Don't treat a non-zero exit as an answer**: the wrapper prints "UNREVIEWED" when the turn died; retry once, then report the review as not run

## Parameter Quick Reference

| Parameter | Plan Review | Implementation |
|-----------|------------|----------------|
| `--sandbox` | `read-only` | `workspace-write` |
| `--role` | `~/.claude/skills/plan-codex/codex-analyzer-role.md` | `~/.claude/skills/execute-codex/codex-architect-role.md` |
| `--cd` | Project root | Project root |
| model and effort | `review` profile in `~/.codex/review.config.toml` | same |
