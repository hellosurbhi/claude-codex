---
description: "Claude plans with Opus, Codex re-audits until no findings remain"
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

### Phase 2: Codex Audit Loop (no iteration cap, no severity floor)

Read `~/.claude/skills/plan-codex/codex-analyzer-role.md` and pass as `--role <file>`. (That file defines the `VERDICT: APPROVED | WARNING | BLOCKED` grammar the parse step below branches on; `prompts/codex/analyzer.md` also exists but predates the verdict contract and defines no grammar, so it must not be used here.)

**MANDATORY Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, **stop and tell the user**: "Codex CLI or codex-call.sh is not available. This command requires Codex." Do NOT skip or bypass this phase. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

**MANDATORY mid-call failure handling**: a Codex call that errors, times out or is aborted mid-audit is NOT an approval and NOT a skippable step. `codex-call.sh` exits non-zero when the turn did not complete; treat that as a dead call and retry it exactly once with the same arguments, then validate the output against the same `VERDICT:` grammar below. If the retry also dies with a named quota or usage-limit error, follow the usage-limit carve-out below. If it dies for any other reason, **stop and tell the user**: "Codex audit incomplete. The review did not run. The plan is UNREVIEWED." Never proceed to Phase 3 on a dead audit in that case.

**Usage-limit carve-out (never block on quota, owner mandate 2026-08-26: "never block cause codex")**: if the retry also dies AND the error is a quota or usage-limit error (the tool names its own reset time, e.g. "usage limit... try again at <time>", not a transport failure or an unexplained timeout), do NOT stop. The plan audit is a best-effort pre-code check; the repo's push-time Codex review is the enforcement boundary and already queues the same outage for a re-review once quota returns. Append a `## Audit status` section to `.claude/plan/<feature-name>.md`: "Plan audit SKIPPED: Codex usage limit (tool reported: '<verbatim message>'). Relies on this repo's push-time Codex review of the resulting diff." Tell the user in one line ("Plan audit deferred: Codex is over quota until <time>; proceeding without it, push-time review still covers the diff") and go to Phase 3 with no further Codex call. This matches `skills/plan-codex/SKILL.md`.

**Call `codex-call.sh`** (iteration 1):
- prompt: "Read the plan file at `.claude/plan/<feature-name>.md` and audit it for correctness, completeness, security, and edge cases. Return the structured verdict (VERDICT: APPROVED | WARNING | BLOCKED) with severity-prefixed findings per your instructions."
- flag: `--sandbox read-only`
- append to prompt: (`--role ~/.claude/skills/plan-codex/codex-analyzer-role.md`) "\nBe concise. Output result only, no reasoning process."

Save the returned `THREAD_ID`.

**Parse the exact `VERDICT:` line** (line-anchored; exactly one must be present). The word APPROVED appearing inside prose or a finding is NOT approval. A response with no verdict line, multiple verdict lines, or a value other than APPROVED, WARNING or BLOCKED is malformed: retry the call once, and if the retry is also malformed, stop and tell the user the plan is UNREVIEWED.
**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the actual codebase, whether the reviewer had full context for intentional decisions, and whether it improves the plan or is a preference/false positive. Contest doubtful findings via `codex-call.sh --resume <THREAD_ID>` with specific reasoning; discussion replies do not count as audit iterations. Only findings that survive this gate are "accepted" below.
- Any accepted finding at any severity (BLOCKED, WARNING, or APPROVED with MEDIUM/LOW findings) → fix every accepted finding, revise the plan, update `.claude/plan/<feature-name>.md`, re-audit
- A round with no findings, or whose every finding was dropped through the gate's discussion path → go to Phase 3

**Call `codex-call.sh --resume <THREAD_ID>`** (iteration 2 onward):
- THREAD_ID: {saved THREAD_ID}
- prompt: "The plan has been revised to address your feedback. Re-read the plan file at `.claude/plan/<feature-name>.md` and audit it again for correctness, completeness, security, and edge cases. Return the structured verdict (VERDICT: APPROVED | WARNING | BLOCKED) with severity-prefixed findings per your instructions."

There is no iteration cap and no stop to ask the user: keep revising and re-auditing until a round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). This matches `skills/plan-codex/SKILL.md`.

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
