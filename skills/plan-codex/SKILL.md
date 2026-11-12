---
name: plan-codex
description: "Create a detailed implementation plan with Opus-level reasoning, then Codex audits it for correctness, completeness and security and re-audits until a round has no accepted findings at any severity. Best for: planning before coding — never modifies production code. Triggers on: /plan-codex, plan a feature, create implementation plan, design a system, architect this."
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
- `Bash` running `~/.claude/config/scripts/codex-call.sh` (wraps `codex exec`; follow-ups use `--resume THREAD_ID`) — Codex audit loop
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

### Phase 2: Codex Audit (re-audit until a round has no accepted findings at any severity; no iteration cap)

**MANDATORY Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, **stop and tell the user**: "Codex CLI or codex-call.sh is not available. This skill requires Codex." Do NOT skip or bypass this phase. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

**MANDATORY mid-call failure handling**: a Codex call that errors, times out, or exits without a final message (`codex-call.sh` exits non-zero with "UNREVIEWED") is NOT an approval and NOT a skippable step. Retry the same `codex-call.sh` call exactly once, and validate the output against the same VERDICT grammar.

**Usage-limit carve-out (never block on quota, owner mandate 2026-08-26: "never block cause codex")**: if the retry also dies AND the error is a quota/usage-limit error (the tool names its own reset time, e.g. "usage limit... try again at <time>", as opposed to a transport failure or unexplained timeout) — do NOT stop. This is a self-resolving external constraint, not a broken review, and this skill's audit is a best-effort pre-code check, not the actual enforcement boundary: the repo's push-time Codex review is that boundary, and it already degrades gracefully on the identical failure (`reviewer.sh`'s outage path logs to `reviews/retry-queue.md` and exits nonblocking; `retry-skipped-reviews.sh` re-reviews the real diff once quota returns — non-config repos never blocked on this in the first place). Append a `## Audit status` section to `.claude/plan/<feature-name>.md`: "Plan audit SKIPPED, the plan is UNREVIEWED: Codex usage limit (tool reported: '<verbatim message>'). Relies on this repo's push-time Codex review of the resulting diff." Tell the user in one line ("Plan audit skipped: Codex is over quota until <time>, so this plan is UNREVIEWED; push-time review still covers the diff"). Never call a skipped audit approved or reviewed. Then go straight to Phase 3 / implementation with no further Codex call.

If the retry dies for any OTHER reason (transport failure, timeout with no reset time given, or any error that isn't a named quota limit): **stop and tell the user**: "Codex audit incomplete — the review did not run. The plan is UNREVIEWED." Never proceed to Phase 3 or to implementation on a dead audit for these cases; an unreviewed plan must be labeled as such, out loud, every time. (Added 2026-07-28 after an xhigh audit was silently killed by a 1800s MCP idle timeout and work continued without it. Usage-limit carve-out added 2026-08-26: a multi-hour quota wall was stalling all work in the security-boundary repo for zero extra safety, since push-time review already catches the same outage the same way.)

Pass the installed path `~/.claude/skills/plan-codex/codex-analyzer-role.md` as `--role` (an absolute path: a bare filename is read relative to the project directory).

**Call `codex-call.sh`** (iteration 1):
- prompt: "Read the plan file at `.claude/plan/<feature-name>.md` and audit it for correctness, completeness, security, and edge cases. Reply APPROVED if solid, or list specific issues to fix."
- flag: `--sandbox read-only`
- append to prompt: (`--role ~/.claude/skills/plan-codex/codex-analyzer-role.md`) "\nBe concise. Output result only, no reasoning process."

Save the returned `THREAD_ID`.

**Parse the VERDICT line** (the analyzer role emits `VERDICT: APPROVED | WARNING | BLOCKED`):
Every verdict is handled the same way: the severity of a finding decides how urgent it is, never whether it gets fixed.
- **Any findings at any severity** (BLOCKED, WARNING, or APPROVED with MEDIUM/LOW findings listed) → critically evaluate each one (see below), fix every accepted finding in the plan, update `.claude/plan/<feature-name>.md`, and re-audit.
- **Done** → a round that lists no findings, or whose every finding was dropped through the discussion path below. Only then go to Phase 3.

**Critical Evaluation of Audit Findings**

Before addressing any issues, critically evaluate each finding:

1. **Assess correctness**: Is the finding technically accurate given the codebase and requirements?
2. **Check context**: Does the reviewer have full context about architectural decisions and constraints?
3. **Verify applicability**: Does the suggestion improve the plan, or is it a preference / false positive?

**If a finding seems incorrect or questionable:**
- Do NOT address it or count it as an iteration. Instead, reply to the reviewer with your technical reasoning.
- Call `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) explaining why the finding appears incorrect, with specific references to the plan and codebase.
- If the reviewer provides additional justification that is convincing, accept the finding.
- If the reviewer concedes or cannot justify further, drop the finding.
- Discussion replies do NOT increment the iteration counter — only revise-and-re-audit cycles count.

**If findings are accepted:** address every accepted issue, revise plan, update `.claude/plan/<feature-name>.md`.

**Call `codex-call.sh --resume <THREAD_ID>`** (iteration 2 onward, after every round with accepted findings):
- THREAD_ID: {saved THREAD_ID}
- prompt: "The plan has been revised to address your feedback. Re-read the plan file at `.claude/plan/<feature-name>.md` and audit it again for correctness, completeness, security, and edge cases. Reply APPROVED if solid, or list specific issues to fix."

There is no iteration cap and no stop to ask the user: keep revising and re-auditing until a round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). There is no severity floor either: a WARNING or a MEDIUM/LOW finding gets fixed and re-audited exactly like a CRITICAL. What ends the loop on preferences and false positives is the discussion path, never a round count. A finding that comes back after you addressed it is a disagreement, not a reason to stop: settle it through the discussion path above (Codex either justifies it, and you fix it properly, or concedes). Stop only on the dead-audit rules above.

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
