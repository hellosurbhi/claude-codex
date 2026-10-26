---
description: "Claude plans with Opus, Codex audits once, re-audit only on BLOCKED"
argument-hint: "<task description>"
model: claude-opus-4-6
allowed-tools: ["AskUserQuestion", "Task", "Read", "Glob", "Grep", "Write", "Bash"]
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

Read `~/.claude/skills/plan-codex/codex-analyzer-role.md` and pass as `--role <file>`. (That file defines the `VERDICT: APPROVED | WARNING | BLOCKED` grammar the parse step below branches on; `prompts/codex/analyzer.md` also exists but predates the verdict contract and defines no grammar, so it must not be used here.)

**Call `codex-call.sh`** (iteration 1):
- prompt: "Read the plan file at `.claude/plan/<feature-name>.md` and audit it for correctness, completeness, security, and edge cases. Return the structured verdict (VERDICT: APPROVED | WARNING | BLOCKED) with severity-prefixed findings per your instructions."
- flag: `--sandbox read-only`
- append to prompt: (`--role ~/.claude/skills/plan-codex/codex-analyzer-role.md`) "\nBe concise. Output result only, no reasoning process."

Save the returned `THREAD_ID`.

**Parse the exact `VERDICT:` line** (line-anchored; exactly one must be present). The word APPROVED appearing inside prose or a finding is NOT approval. A response with no verdict line, multiple verdict lines, or a value other than APPROVED, WARNING or BLOCKED is malformed: retry the call once, and if the retry is also malformed, stop and tell the user the plan is UNREVIEWED.
**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the actual codebase, whether the reviewer had full context for intentional decisions, and whether it improves the plan or is a preference/false positive. Contest doubtful findings via `codex-reply` with specific reasoning; discussion replies do not count as audit iterations. Only findings that survive this gate are "accepted" below.
- `VERDICT: APPROVED` → fold any accompanying MEDIUM/LOW findings into the plan's notes (the analyzer role explicitly permits them), update `.claude/plan/<feature-name>.md` with final version, go to Phase 3
- `VERDICT: WARNING` (no CRITICAL) → fold the accepted findings into the plan, update `.claude/plan/<feature-name>.md`, go to Phase 3 with no further Codex call
- `VERDICT: BLOCKED` (CRITICAL findings) → address every CRITICAL and any accompanying HIGH findings, revise plan, update `.claude/plan/<feature-name>.md`, re-audit

**Call `codex-call.sh --resume <THREAD_ID>`** (iterations 2-3):
- THREAD_ID: {saved THREAD_ID}
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
