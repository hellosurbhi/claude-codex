---
description: "Claude plans with Opus, Codex audits, loop until approved"
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

Read `~/.claude/prompts/codex/analyzer.md` and inject as `developer-instructions`.

**Call `mcp__codex__codex`** (iteration 1):
- prompt: "Read the plan file at `.claude/plan/<feature-name>.md` and audit it for correctness, completeness, security, and edge cases. Return ONLY the structured verdict — `VERDICT: APPROVED | WARNING | BLOCKED` followed by `CRITICAL:` / `HIGH:` / `MEDIUM:` / `LOW:` lines, each a list or 'none'. Use APPROVED only when both CRITICAL and HIGH are 'none'."
- sandbox: "read-only"
- approval-policy: "never"
- developer-instructions: {content of ~/.claude/prompts/codex/analyzer.md} + "\nBe concise. Output result only, no reasoning process."

Save the returned `threadId`.

**Parse response** — always read the `VERDICT:` line together with the severity lines; never accept the verdict on its own:

1. Extract the `VERDICT:` line and the `CRITICAL:` / `HIGH:` / `MEDIUM:` / `LOW:` lines. A missing `VERDICT:` line, or a verdict other than `APPROVED` / `WARNING` / `BLOCKED`, is malformed → step 4.
2. **Consistency check** — the verdict must match the findings:
   - `APPROVED` requires `CRITICAL: none` **and** `HIGH: none`
   - `WARNING` requires `CRITICAL: none` and at least one HIGH finding
   - `BLOCKED` requires at least one CRITICAL finding

   Any other combination — e.g. `VERDICT: APPROVED` alongside a non-`none` `CRITICAL:` or `HIGH:` list — is contradictory, therefore malformed → step 4.
3. Consistent verdict:
   - `APPROVED` → update `.claude/plan/<feature-name>.md` with final version, go to Phase 3
   - `WARNING` / `BLOCKED` → address every CRITICAL and HIGH issue, revise plan, update `.claude/plan/<feature-name>.md`, re-audit
4. Malformed or contradictory response → do **not** go to Phase 3 and do **not** drop the reported findings. Call `mcp__codex__codex-reply` (reuse threadId), quote the contradiction, and ask for a corrected verdict in the exact format. A correction request does not count as an audit iteration. If the corrected response is still malformed, treat it as `BLOCKED`: fix every reported CRITICAL/HIGH finding, revise the plan, and re-audit.

**Call `mcp__codex__codex-reply`** (iterations 2-3):
- threadId: {saved threadId}
- prompt: "The plan has been revised to address your feedback. Re-read the plan file at `.claude/plan/<feature-name>.md` and audit it again for correctness, completeness, security, and edge cases. Return ONLY the structured verdict in the same format. Use APPROVED only when both CRITICAL and HIGH are 'none'."

After 3 iterations without APPROVED, stop and ask user for direction.

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
