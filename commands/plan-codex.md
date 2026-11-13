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

**MANDATORY mid-call failure handling**: a Codex call that errors, times out, exits without a final message (`codex-call.sh` exits non-zero with "UNREVIEWED") or replies without exactly one valid `VERDICT:` line is NOT an approval and NOT a skippable step. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`; the CodeRabbit CLI reviews committed changes only, not a plan file), and validate every answer against the same VERDICT grammar. Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved one for every later `--resume`; the CodeRabbit CLI has no thread and takes no prompt, so each follow-up is a fresh review of the new committed state, and a finding you contest is settled only by a Codex reviewer's explicit concession. Stop only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker. When that blocker is anything other than a named usage limit: **stop and tell the user**: "Codex audit incomplete: <blocker>. The plan is UNREVIEWED." Never proceed to Phase 3 or to implementation on a dead audit in that case; an unreviewed plan must be labeled as such, out loud, every time. (Added 2026-07-28 after an xhigh audit was silently killed by a 1800s MCP idle timeout and work continued without it. One-retry cutoff removed 2026-11-12.)

**Usage-limit carve-out (never block on quota, owner mandate 2026-08-26: "never block cause codex")**: when Codex dies with a quota or usage-limit error (the tool names its own reset time, e.g. "usage limit... try again at <time>", not a transport failure or an unexplained timeout), switch to another independent reviewer first, as above. Only if every other reviewer is also unavailable, do NOT stop: the plan audit is a best-effort pre-code check, and the repo's push-time Codex review is the enforcement boundary that already queues the same outage for a re-review once quota returns. Append a `## Audit status` section to `.claude/plan/<feature-name>.md`: "Plan audit SKIPPED, the plan is UNREVIEWED: Codex usage limit (tool reported: '<verbatim message>'); <other reviewers and why each was unavailable>. Relies on this repo's push-time Codex review of the resulting diff." Tell the user in one line ("Plan audit skipped: Codex is over quota until <time> and no other reviewer is available, so this plan is UNREVIEWED; push-time review still covers the diff"). Never call a skipped audit approved or reviewed. Then go to Phase 3 with no further Codex call. This matches `skills/plan-codex/SKILL.md`.

**Call `codex-call.sh`** (iteration 1):
- prompt: "Read the plan file at `.claude/plan/<feature-name>.md` and audit it for correctness, completeness, security and edge cases. Return the structured verdict (VERDICT: APPROVED | WARNING | BLOCKED) with severity-prefixed findings per your instructions."
- flag: `--sandbox read-only`
- append to prompt: (`--role ~/.claude/skills/plan-codex/codex-analyzer-role.md`) "\nBe concise. Output result only, no reasoning process."

Save the returned `THREAD_ID`.

**Parse the exact `VERDICT:` line** (line-anchored; exactly one must be present). The word APPROVED appearing inside prose or a finding is NOT approval. A response with no verdict line, multiple verdict lines or a value other than APPROVED, WARNING or BLOCKED is malformed, which is a failed call: handle it with the mid-call failure rules above (fix the cause and retry or switch reviewer until a valid verdict arrives).
**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the actual codebase, whether the reviewer had full context for intentional decisions and whether it improves the plan or is a preference/false positive. Contest doubtful findings via `codex-call.sh --resume <THREAD_ID>` with specific reasoning; a finding is dropped only when the reviewer explicitly concedes it in a written reply; a reviewer that maintains it, or a reply with no clear concession, leaves it accepted and it gets fixed, and your own disagreement never drops a finding. Only findings that survive this gate are "accepted" below.
- Any accepted finding at any severity (BLOCKED, WARNING, or APPROVED with MEDIUM/LOW findings) → fix every accepted finding, revise the plan, update `.claude/plan/<feature-name>.md`, re-audit
- A round with no findings, or whose every finding was dropped through the gate's discussion path → go to Phase 3

**Call `codex-call.sh --resume <THREAD_ID>`** (iteration 2 onward):
- THREAD_ID: {saved THREAD_ID}
- prompt: "The plan has been revised to address your feedback. Re-read the plan file at `.claude/plan/<feature-name>.md` and audit it again for correctness, completeness, security and edge cases. Return the structured verdict (VERDICT: APPROVED | WARNING | BLOCKED) with severity-prefixed findings per your instructions."

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
