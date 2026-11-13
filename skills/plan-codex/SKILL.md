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

**MANDATORY mid-call failure handling**: a Codex call that errors, times out, exits without a final message (`codex-call.sh` exits non-zero with "UNREVIEWED") or replies without exactly one valid `VERDICT:` line is NOT an approval and NOT a skippable step. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or the CodeRabbit CLI via `~/.claude/config/scripts/reviewer.sh R <plan-file> <out-file>`), and validate every answer against the same VERDICT grammar. Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). Stop only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable, and name the blocker. When that blocker is anything other than a named usage limit: **stop and tell the user**: "Codex audit incomplete: <blocker>. The plan is UNREVIEWED." Never proceed to Phase 3 or to implementation on a dead audit in that case; an unreviewed plan must be labeled as such, out loud, every time. (Added 2026-07-28 after an xhigh audit was silently killed by a 1800s MCP idle timeout and work continued without it. One-retry cutoff removed 2026-11-12.)

**Usage-limit carve-out (never block on quota, owner mandate 2026-08-26: "never block cause codex")**: when Codex dies with a quota or usage-limit error (the tool names its own reset time, e.g. "usage limit... try again at <time>", not a transport failure or an unexplained timeout), switch to another independent reviewer first, as above. Only if every other reviewer is also unavailable, do NOT stop: the plan audit is a best-effort pre-code check, and the repo's push-time Codex review is the enforcement boundary that already queues the same outage for a re-review once quota returns. Append a `## Audit status` section to `.claude/plan/<feature-name>.md`: "Plan audit SKIPPED, the plan is UNREVIEWED: Codex usage limit (tool reported: '<verbatim message>'); <other reviewers and why each was unavailable>. Relies on this repo's push-time Codex review of the resulting diff." Tell the user in one line ("Plan audit skipped: Codex is over quota until <time> and no other reviewer is available, so this plan is UNREVIEWED; push-time review still covers the diff"). Never call a skipped audit approved or reviewed. Then go to Phase 3 with no further Codex call.

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
- Do NOT address it yet. Instead, reply to the reviewer with your technical reasoning.
- Call `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) explaining why the finding appears incorrect, with specific references to the plan and codebase.
- If the reviewer provides additional justification that is convincing, accept the finding.
- Drop the finding only when the reviewer explicitly concedes it in writing. If it maintains the finding or gives no clear answer, accept it and fix it; your own disagreement never drops a finding.
- A discussion reply never ends the loop by itself: the loop ends only when a round has no accepted findings.

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
