# Codex MCP Reference — Detailed Patterns

## Starting a Review Session

```
mcp__codex__codex:
  prompt: |
    Review this implementation plan for correctness, completeness,
    security, and edge cases. Reply APPROVED if solid, or list
    specific issues to fix.

    <plan>
    {plan content here}
    </plan>
  sandbox: "read-only"
  approval-policy: "never"
  developer-instructions: |
    You are a senior architect reviewing implementation plans.
    Be thorough but practical. Only flag real issues, not stylistic preferences.
    Be concise. Do not include your reasoning process in the response.
    Only output the result.
```

## Starting an Implementation Session

```
mcp__codex__codex:
  prompt: |
    Implement the following task. Write production-quality code.

    {task description or plan content}
  sandbox: "workspace-write"
  approval-policy: "on-failure"
  developer-instructions: |
    Write clean, tested, production code. Follow existing project conventions.
    Do not modify unrelated files. Be concise.
    Do not include your reasoning process in the response.
    Only output the result.
```

## Continuing with Feedback

```
mcp__codex__codex-reply:
  threadId: "{saved threadId from initial call}"
  prompt: |
    Fix these issues from code review:
    - auth.ts:42 — missing null check on user.email
    - api.ts:15 — no rate limiting on /login endpoint
    Reimplement with these fixes.
```

## Loop Termination Signals

| Loop Type | Termination Signal | Who Decides |
|-----------|-------------------|-------------|
| Plan review | Codex states APPROVED as its verdict **and** reports no CRITICAL or HIGH findings | Codex |
| Execute review | Claude reviewer states APPROVED as its verdict **and** reports no CRITICAL or HIGH findings | Claude |

Never terminate on a substring match for "APPROVED" alone. A verdict that
contradicts the findings in the same response is malformed, not an approval:
`VERDICT: APPROVED` alongside a populated `CRITICAL:` or `HIGH:` list, `NOT
APPROVED`, "APPROVED once you fix …", or two conflicting verdicts. Reply asking
for a single unambiguous verdict rather than exiting the loop and dropping the
findings.

Always enforce a max iteration count (default: 3). The shipped skills use 3
rounds for plan audits, Codex implementation and implementation reviews, and 2
rounds for test audits and the Route A code review.

The cap fails closed. When it is reached without a valid approval, **stop**:
report the unresolved findings and ask the user for direction. Do not advance to
the next phase and do not deliver; continuing is prohibited without an explicit
user instruction to proceed. Clarification replies (asking for an unambiguous
verdict, or contesting a finding) do not increment the counter; only
revise-and-re-review cycles do.

## Anti-Patterns

- **Don't start new sessions per iteration** — wastes context, loses conversation history
- **Don't summarize reviewer feedback** — Codex needs exact file:line references to fix issues
- **Don't use `danger-full-access` sandbox** — `workspace-write` is sufficient for implementation
- **Don't skip `developer-instructions`** — it shapes response quality significantly
- **Don't exit a loop on a substring match for "APPROVED"** — a verdict that contradicts the findings in the same response is malformed, and treating it as approval silently drops CRITICAL/HIGH issues
- **Don't proceed after the iteration cap** — hitting the cap without an approval means stop and ask the user, not deliver anyway
- **Don't omit conciseness instruction** — Codex may include lengthy reasoning that wastes context tokens
- **Don't add `2>/dev/null` to tool calls** — MCP handles this at the server process level

## Parameter Quick Reference

| Parameter | Plan Review | Implementation |
|-----------|------------|----------------|
| sandbox | `read-only` | `workspace-write` |
| approval-policy | `never` | `on-failure` |
| developer-instructions | Architect reviewer persona | Coding standards + conciseness |
| cwd | Project root | Project root |
