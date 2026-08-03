---
description: "Claude plans with Opus, Codex audits once, re-audit only on BLOCKED"
argument-hint: "<task description>"
model: claude-opus-4-6
allowed-tools: ["AskUserQuestion", "mcp__codex__codex", "mcp__codex__codex-reply", "Task", "Read", "Glob", "Grep", "Write", "Bash"]
---

> **Deprecated**: This command has been converted to a skill (`/plan-codex`).
> The skill version is recommended for new usage and supports eval-based testing.
> This command is retained for backward compatibility (model pinning, tool restrictions).

# Plan-Codex — Claude Plans, Codex Audits

$ARGUMENTS

---

## Core Protocols

- **Code Sovereignty**: Codex has zero filesystem write access during planning — all file operations by Claude only
- **Stop-Loss**: Do not proceed to next phase until current phase output is validated
- **Language**: Use English when calling tools/models; communicate with user in their language
- **Planning Only**: Never modify production code during this command

---

## Execution Workflow

### Phase 1: Plan Creation

Launch a Task agent (subagent_type: "Plan") with the task description.
The Plan agent will research the codebase and return a structured implementation plan.

If requirements are ambiguous before launching the planner, ask clarifying questions first.

Save the returned plan to `.claude/plan/<feature-name>.md`.

### Phase 2: Codex Audit Loop (max 3 iterations)

Read `~/.claude/skills/plan-codex/codex-analyzer-role.md` and inject as `developer-instructions`. (That file defines the `VERDICT: APPROVED | WARNING | BLOCKED` grammar the parse step below branches on; the old `~/.claude/prompts/codex/analyzer.md` path does not exist in this install.)

**Call `mcp__codex__codex`** (iteration 1):
- prompt: "Read the plan file at `.claude/plan/<feature-name>.md` and audit it for correctness, completeness, security, and edge cases. Return the structured verdict (VERDICT: APPROVED | WARNING | BLOCKED) with severity-prefixed findings per your instructions."
- sandbox: "read-only"
- approval-policy: "never"
- developer-instructions: {content of ~/.claude/skills/plan-codex/codex-analyzer-role.md} + "\nBe concise. Output result only, no reasoning process."

Save the returned `threadId`.

**Parse response**:
- Contains "APPROVED" → update `.claude/plan/<feature-name>.md` with final version, go to Phase 3
- WARNING (no CRITICAL) → fold the accepted findings into the plan, update `.claude/plan/<feature-name>.md`, go to Phase 3 with no further Codex call
- BLOCKED (CRITICAL findings) → address every CRITICAL and any accompanying HIGH findings, revise plan, update `.claude/plan/<feature-name>.md`, re-audit

**Call `mcp__codex__codex-reply`** (iterations 2-3):
- threadId: {saved threadId}
- prompt: "The plan has been revised to address your feedback. Re-read the plan file at `.claude/plan/<feature-name>.md` and audit it again for correctness, completeness, security, and edge cases. Return the structured verdict (VERDICT: APPROVED | WARNING | BLOCKED) with severity-prefixed findings per your instructions."

After 3 iterations still BLOCKED, stop and ask user for direction.

### Phase 3: Deliver

Present the final plan and output:

---
**Plan saved to `.claude/plan/<feature-name>.md`**

Review the plan above. When ready, start a new session and run:
```
/execute-codex .claude/plan/<feature-name>.md
```
---

**Stop here. Do not auto-execute.**
