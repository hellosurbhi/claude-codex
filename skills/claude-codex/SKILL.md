---
name: claude-codex
description: "Claude implements code changes, Codex reviews via `codex exec` with structured APPROVED/WARNING/BLOCKED verdicts. Best for: straightforward implementation where you want an external Codex review. Triggers on: /claude-codex, implement and review, build with Codex review, code with external review."
---

# Claude-Codex — Claude Implements, Codex Reviews

## Input

The user's message after the trigger is either:
1. A file path to a plan (e.g. `.claude/plan/feature.md`) — read it and extract task description, implementation steps, key files
2. A direct task description — use as-is

Confirm with user before proceeding if key context is missing.

## Model Recommendation

Works with any model (default: `claude-sonnet-4-6`). Override with `/model opus` for complex tasks requiring deeper reasoning.

## Tool Requirements

Advisory checklist — ensure these tools are available:
- `AskUserQuestion` — confirm missing context
- `Task` — dispatch implementation subagents
- `Read`, `Glob`, `Grep` — context retrieval
- `Write`, `Edit` — implement changes
- `Bash` — run lint/tests/git commands
- `Bash` running `~/.claude/config/scripts/codex-call.sh` (wraps `codex exec`; follow-ups use `--resume THREAD_ID`) — Codex review

## Core Protocols

- **Sovereignty**: Claude implements; Codex is the external reviewer — do not skip review
- **Stop-Loss**: Do not proceed to the next phase until the current phase output is validated
- **Language**: Use English when calling tools/models; communicate with user in their language
- **Wrapper for review**: Always call Codex review via `codex-call.sh`. Do NOT use bare `codex review`: it produces verbose output that wastes context.
- **Context Sanitization**: Never pass `.env`, secrets, tokens, API keys, or credentials to any external agent or MCP. Exclude files matching `.env*`, `*secret*`, `*credential*`, `*.pem`, `*.key`. Redact inline secrets before sending.

## Execution Workflow

### Phase 0: Read Plan

1. If argument is a file path, read it and extract: task description, implementation steps, key files
2. If no plan file, use the argument as the task description directly
3. Confirm with user before proceeding if key context is missing

### Phase 1: Context Retrieval

Read key files using Read, Glob, Grep. Confirm complete context before proceeding.

### Phase 2: Claude Implements

**If the plan has 3+ implementation tasks**, dispatch each task to a subagent to keep the main context clean:

For each task (sequentially — next task starts only after current task is verified):
1. Record `$TASK_SHA` via `git rev-parse HEAD` before dispatching
2. Launch a general-purpose Task agent with:
   - The specific task description and acceptance criteria
   - Sanitized key file contents it needs to read/modify
   - Instruction: "Implement only this task. Run available lint/tests scoped to changed files after implementing. Report: files changed, verification result, any blockers."
3. After the subagent completes: run `git diff $TASK_SHA` (scoped to this task only) to verify what changed, run scoped lint/tests to confirm no regressions
4. If the subagent reports a blocker or verification fails: fix directly with Edit/Write or re-dispatch with the failure output

**If the plan has fewer than 3 tasks**, implement directly with Edit/Write.

After all tasks complete (either path):
- Run lint / typecheck / tests if available (minimal related scope)
- Fix any regressions before proceeding to review

### Phase 3: Codex Review (max 3 iterations)

**MANDATORY Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, **stop and tell the user**: "Codex CLI or codex-call.sh is not available. This skill requires Codex." Do NOT skip or bypass this phase. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

**Step R1 — Run Codex Review via codex-call.sh**

Call Codex via `codex-call.sh` with:
- append to prompt: `"Be concise. Return only the structured verdict format. No prose."`
- `prompt`:

```
Run `git diff HEAD` to see all uncommitted changes, then review them.

Return ONLY a structured verdict in this exact format — no explanations, no prose:

VERDICT: APPROVED | WARNING | BLOCKED

CRITICAL: <list or 'none'>
HIGH: <list or 'none'>
MEDIUM: <list or 'none'>
LOW: <list or 'none'>
```

Save the returned `THREAD_ID` for follow-up replies.

Classify the verdict:
- **APPROVED** — no CRITICAL or HIGH → go to Phase 4
- **WARNING** — HIGH issues only → critically evaluate (R1.5), fix all accepted HIGHs in one batch, run available tests/lint on the fixes, handle MEDIUM/LOW per Step R3, then go to Phase 4 with **no re-review call**. The HIGHs are fixed and verified; only the paid re-verification round is skipped. (Re-reviewing WARNINGs is what turned 1 review into 3+ xhigh calls per task.)
- **BLOCKED** — CRITICAL issues → fix all, increment iteration, re-review

**Step R1.5 — Critical Evaluation of Review Findings**

Before fixing any issues, critically evaluate each CRITICAL/HIGH finding:

1. **Assess correctness**: Is the finding technically accurate? Check the actual code and project conventions.
2. **Check context**: Does the reviewer have full context, or is it flagging intentional design decisions?
3. **Verify applicability**: Does the suggestion improve correctness/security, or is it a style preference / false positive?

**If a finding seems incorrect or questionable:**
- Do NOT fix it or count it as an iteration. Instead, reply to the reviewer with your technical reasoning.
- Call `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) explaining why the finding appears incorrect, with specific code references.
- If the reviewer provides additional justification that is convincing, accept the finding and include it in the fix batch.
- If the reviewer concedes or cannot justify further, drop the finding.
- Discussion replies do NOT increment the iteration counter — only fix-and-re-review cycles count.

**If all findings appear correct:** proceed directly to Step R2.

**Step R2 — Fix and Re-review (BLOCKED verdicts only)**

Address ALL CRITICAL and HIGH issues before re-reviewing:
- Collect every CRITICAL/HIGH finding from the last review
- Fix them all with Edit/Write in one batch
- Run available tests/lint to verify
- Re-call Codex via `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) with:

```
Run `git diff HEAD` again to see the updated changes after fixes, then re-review.

Return ONLY the structured verdict in the same format.
```

One review per iteration, not one review per fix. Only BLOCKED verdicts trigger a re-review; a re-review that comes back WARNING follows the WARNING rule above (fix accepted HIGHs, proceed, no further call).

After 3 iterations still BLOCKED, stop and report remaining issues to user.

**Step R3 — MEDIUM / LOW Issues**

After CRITICAL/HIGH are resolved, collect any remaining MEDIUM and LOW issues from the last review.
If any exist, ask the user:

> "Codex flagged N MEDIUM/LOW issue(s) that were not fixed:
> - [list issues]
> Should I fix these before delivery, or proceed as-is?"

Wait for user response before proceeding.

---

### Phase 4: Delivery

```markdown
## Execution Complete

### Changes
| File | Operation | Description |
|------|-----------|-------------|
| path/to/file | Modified | Description |

### Review Result
- Implemented by: Claude (active model)
- Codex review: APPROVED / N issues resolved (N/3 iterations)
- Remaining MEDIUM/LOW issues: N (skipped by user) / none

### Recommended Next Steps
1. [ ] <test step>
2. [ ] <verification step>
```
