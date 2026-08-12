---
name: plan-codex
description: "Create a detailed implementation plan with Opus-level reasoning, then Codex audits it once for correctness, completeness, and security; only a BLOCKED verdict triggers re-audit. Best for: planning before coding — never modifies production code. Triggers on: /plan-codex, plan a feature, create implementation plan, design a system, architect this."
---

# Plan-Codex — Claude Plans, Codex Audits

## Input

The user's message after the trigger is either:
1. A file path to an existing plan or requirements doc — read it and extract task description, goals, constraints
2. A direct task description — use as-is

Confirm with user before proceeding if key context is missing.

## Model Recommendation

Works best with `claude-opus-4-6`. Override with `/model opus` before invoking for complex architectural tasks.

## Tool Requirements

Advisory checklist — ensure these tools are available:
- `AskUserQuestion` — ask clarifying questions
- `mcp__codex__codex` and `mcp__codex__codex-reply` — Codex audit loop
- `Task` — launch planner subagent
- `Read`, `Glob`, `Grep` — codebase research
- `Write`, `Bash` — save plan file

## Core Protocols

- **Code Sovereignty**: Codex has zero filesystem write access during planning — all file operations by Claude only
- **Stop-Loss**: Do not proceed to next phase until current phase output is validated
- **Language**: Use English when calling tools/models; communicate with user in their language
- **Planning Only**: Never modify production code during this skill

## Execution Workflow

### Phase 1: Plan Creation

Launch a Task agent (subagent_type: "Plan") with the task description.
The Plan agent will research the codebase and return a structured implementation plan.

If requirements are ambiguous before launching the planner, ask clarifying questions first.

Save the returned plan to `.claude/plan/<feature-name>.md`.

### Phase 2: Codex Audit (single pass; re-audit only on BLOCKED, max 3 iterations)

**MANDATORY Codex availability check**: `mcp__codex__codex` MUST be listed in the available tools (either in the tool list or in `<available-deferred-tools>`). Do NOT skip or bypass this phase. If the tool is genuinely absent from both locations, **stop and tell the user**: "Codex MCP is not available. This skill requires Codex for plan audit. Please add the Codex MCP server." Do not proceed without Codex — the audit loop is this skill's core value.

**MANDATORY mid-call failure handling**: a Codex call that errors, times out, or is aborted mid-audit (e.g. "sent no response or progress", MCP idle timeout, task failed) is NOT an approval and NOT a skippable step. Retry the call exactly once — if the MCP transport is the thing failing (the per-session MCP connection does not pick up config changes until restart), retry via the CLI with the full audit context supplied explicitly, since a bare `codex exec` with no prompt hangs reading stdin: `codex exec --sandbox read-only "$(cat ~/.claude/skills/plan-codex/codex-analyzer-role.md)"$'\n\n'"Read the plan file at .claude/plan/<feature-name>.md and audit it for correctness, completeness, security, and edge cases. Return the structured verdict."` and validate the output against the same VERDICT grammar. If the retry also dies, **stop and tell the user**: "Codex audit incomplete — the review did not run. The plan is UNREVIEWED." Never proceed to Phase 3 or to implementation on a dead audit; an unreviewed plan must be labeled as such, out loud, every time. (Added 2026-07-28 after an xhigh audit was silently killed by a 1800s MCP idle timeout and work continued without it.)

Read `codex-analyzer-role.md` from this skill directory and inject as `developer-instructions`.

**Call `mcp__codex__codex`** (iteration 1):
- prompt: "Read the plan file at `.claude/plan/<feature-name>.md` and audit it for correctness, completeness, security, and edge cases. Reply APPROVED if solid, or list specific issues to fix."
- sandbox: "read-only"
- approval-policy: "never"
- developer-instructions: {content of codex-analyzer-role.md} + "\nBe concise. Output result only, no reasoning process."

Save the returned `threadId`.

**Parse the VERDICT line** (the analyzer role emits `VERDICT: APPROVED | WARNING | BLOCKED`):
- **APPROVED** → fold any accompanying MEDIUM/LOW findings into the plan's notes, update `.claude/plan/<feature-name>.md` with final version, go to Phase 3.
- **WARNING** (at least one HIGH finding, nothing CRITICAL) → critically evaluate the findings (see below), fold the accepted ones into the plan, note them in the Phase 3 delivery, and go to Phase 3 with **no further Codex call**. Log: "First-pass WARNING, findings incorporated, skipping re-audit." A WARNING plan is a reviewed plan; re-auditing it buys a second 10-15 minute xhigh call to confirm formatting changes. (Measured 2026-08-02: three audit rounds, zero BLOCKED findings, ~45 minutes before any code.)
- **BLOCKED** (CRITICAL findings) → critically evaluate before addressing (see below), then revise and re-audit.

**Critical Evaluation of Audit Findings**

Before addressing any issues, critically evaluate each finding:

1. **Assess correctness**: Is the finding technically accurate given the codebase and requirements?
2. **Check context**: Does the reviewer have full context about architectural decisions and constraints?
3. **Verify applicability**: Does the suggestion improve the plan, or is it a preference / false positive?

**If a finding seems incorrect or questionable:**
- Do NOT address it or count it as an iteration. Instead, reply to the reviewer with your technical reasoning.
- Call `mcp__codex__codex-reply` (reuse threadId) explaining why the finding appears incorrect, with specific references to the plan and codebase.
- If the reviewer provides additional justification that is convincing, accept the finding.
- If the reviewer concedes or cannot justify further, drop the finding.
- Discussion replies do NOT increment the iteration counter — only revise-and-re-audit cycles count.

**If findings are accepted:** address every accepted issue, revise plan, update `.claude/plan/<feature-name>.md`.

**Call `mcp__codex__codex-reply`** (iterations 2-3, **BLOCKED verdicts only**):
- threadId: {saved threadId}
- prompt: "The plan has been revised to address your feedback. Re-read the plan file at `.claude/plan/<feature-name>.md` and audit it again for correctness, completeness, security, and edge cases. Reply APPROVED if solid, or list specific issues to fix."
- A re-audit that comes back WARNING follows the WARNING rule above: incorporate and proceed, no further call.

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
