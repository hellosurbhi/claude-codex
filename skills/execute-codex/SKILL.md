---
name: execute-codex
description: "Smart size-based routing: Claude implements small changes (<=2 files, <=30 lines), Codex implements large changes, code-reviewer agent reviews all. Best for: executing a plan or task where you want automatic routing by complexity. Triggers on: /execute-codex, execute plan, implement with routing, run the plan."
---

# Execute-Codex — Smart Routing: Claude (small) / Codex (large)

## Input

The user's message after the trigger is either:
1. A file path to a plan (e.g. `.claude/plan/feature.md`) — read it and extract task description, implementation steps, key files
2. A direct task description — use as-is

Confirm with user before proceeding if key context is missing.

## Model Recommendation

Works with `claude-sonnet-4-6` (default). No model override needed — routing handles complexity automatically.

## Tool Requirements

Advisory checklist — ensure these tools are available:
- `AskUserQuestion` — confirm missing context
- `Bash` running `~/.claude/config/scripts/codex-call.sh` (wraps `codex exec`; follow-ups use `--resume THREAD_ID`) — Codex implementation (Route B)
- `Task` — dispatch subagents
- `Read`, `Glob`, `Grep` — context retrieval
- `Write`, `Edit` — Claude implementation (Route A)
- `Bash` — run lint/tests/git commands

## Core Protocols

- **Code Sovereignty**: Claude is the final authority — review and approve all changes before delivery
- **Stop-Loss**: Do not proceed to next phase until current phase output is validated
- **Language**: Use English when calling tools/models; communicate with user in their language
- **Context Sanitization**: Never pass `.env`, secrets, tokens, API keys, or credentials to any external agent or MCP. Exclude files matching `.env*`, `*secret*`, `*credential*`, `*.pem`, `*.key`. Redact inline secrets before sending.

## Execution Workflow

### Phase 0: Read Plan

1. If argument is a file path, read it and extract: task description, implementation steps, key files
2. If no plan file, use the argument as the task description directly
3. Confirm with user before proceeding if key context is missing

### Phase 1: Context Retrieval

Read key files using Read, Glob, Grep. Confirm complete context before proceeding.

### Phase 2: Route by Change Size

Classify the task before doing any implementation:

**Small change** — ALL of the following must be true:
- Touches ≤ 2 files
- Estimated diff ≤ 30 lines
- No new abstractions, modules, or significant logic (e.g. config edits, wording fixes, minor additions, single-function tweaks)

**Large change** — any of the following:
- Touches 3+ files
- Estimated diff > 30 lines
- Introduces new logic, new files, refactoring, or cross-cutting concerns

Announce your routing decision before implementing (e.g. "Small change — implementing directly" or "Large change — routing to Codex").

---

### Route A: Small Change — Claude Implements Directly

**If the plan has 3+ implementation tasks**, dispatch each task to a subagent (sequentially):
- Before each task: record `$TASK_SHA` via `git rev-parse HEAD`
- For each task: launch a general-purpose Task agent with the task description, sanitized context files, and instruction: "Implement only this task. Run available lint/tests scoped to changed files. Report: files changed, verification result, any blockers."
- After each subagent: run `git diff $TASK_SHA` (scoped to this task only) to verify changes, run scoped lint/tests to confirm no regressions
- If the subagent reports a blocker: fix directly with Edit/Write or re-dispatch with failure output

**If fewer than 3 tasks**: apply changes directly with Edit/Write.

After all tasks complete (either path):
1. Run self-verification: lint / typecheck / tests if available
2. Launch Task agent (subagent_type: "feature-dev:code-reviewer") with:
   - `git diff HEAD`
   - Original task requirements
   - Required output: exactly one `VERDICT: APPROVED | WARNING | BLOCKED` line, then `CRITICAL:`, `HIGH:`, `MEDIUM:` and `LOW:` lines listing every finding at that severity (`none` when empty). A reply without exactly one valid verdict line is a failed review: re-launch it.
3. **Critical Evaluation**: Before fixing, critically evaluate each finding, at every severity:
   - **Assess correctness**: Is it technically accurate? Check actual code and project conventions.
   - **Check context**: Does the reviewer have full context, or is it flagging intentional design?
   - **Verify applicability**: Does it improve correctness/security, or is it a style preference / false positive?
   - **If a finding seems incorrect**: Do NOT fix it yet. Launch a new code-reviewer agent with the original diff, the contested findings, and your technical reasoning. Ask it to re-evaluate only the contested items. Keep every finding accepted unless that agent explicitly withdraws it in writing; your own disagreement never drops a finding.
4. After evaluation: any accepted finding at any severity (CRITICAL, HIGH, MEDIUM or LOW) → fix every accepted finding in one batch with Edit/Write, re-run the self-verification from step 1 (lint / typecheck / tests), then re-run the code-reviewer from step 2 on the new `git diff HEAD`.
5. Repeat steps 2 to 4 until a round has no accepted findings. There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved one for every later `--resume`; the CodeRabbit CLI has no thread and takes no prompt, so each follow-up is a fresh review of the new committed state, and a finding you contest is settled only by a Codex reviewer's explicit concession. Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do.
6. Go to Phase 3.

---

### Route B: Large Change — Codex First (review until a round has no accepted findings; no iteration cap)

**MANDATORY**: When Route B is selected, you MUST NOT use Edit/Write tools for implementation. All implementation MUST go through `codex-call.sh`. Claude's role in Route B is context retrieval, verification, and review — not implementation. The ONLY exception is fixing minor regressions found during self-verification (Step B2) that are clearly caused by Codex output (e.g. a missing import, a typo in a generated file).

**No post-routing rationalization**: Once Route B is selected, the routing decision applies to ALL tasks in the plan. Do NOT re-evaluate individual tasks for complexity. If you find yourself thinking "this task is simple enough to do directly" or "this is just a deletion" — STOP. That is the routing decision being second-guessed. The routing already accounted for overall complexity. Every task goes through Codex.

**Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, fall back to Route A and announce: "Codex unavailable: falling back to Claude direct implementation." This fallback is ONLY for when Codex is technically unavailable (the wrapper or the CLI is missing). It MUST NOT be used because a task seems "too simple for Codex" or because Claude judges direct editing would be faster. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

Pass the installed path `~/.claude/skills/execute-codex/codex-architect-role.md` as `--role` (an absolute path: a bare filename is read relative to the project directory) for all Codex calls.

**Step B1 — Dispatch to Codex**

Choose the path based on how the task was provided in Phase 0:

---

**Path 1 (plan file input)** — Pass plan file to Codex; Codex uses agents for parallel execution

When the input was a plan file path, make a single Codex call with the plan file path. Codex reads the plan, identifies task dependencies, and spawns sub-agents to run independent tasks in parallel.

Call `codex-call.sh`:
- prompt: `"Read the plan file at \`{plan_file_path}\`. Implement all tasks listed in the plan. For tasks with no shared file conflicts or ordering dependencies, use sub-agents to run them in parallel. For dependent tasks, execute sequentially after prerequisites complete."`
- flag: `--sandbox workspace-write`
- append to prompt: (`--role ~/.claude/skills/execute-codex/codex-architect-role.md`) `"\nBe concise. Output result only, no reasoning process."`

Save the returned `THREAD_ID`. Proceed to Step B2.

---

**Path 2 (direct task description, 3+ tasks)** — Claude dispatches per-task subagents sequentially

**Note on agent spawning**: Codex runs in a sandboxed shell and cannot spawn Claude agents directly. For direct task descriptions with 3+ tasks, Claude spawns a subagent per task — each subagent owns its Codex thread (its own `THREAD_ID`) for that task, keeping both the main context and each Codex session scoped and clean.

For each implementation task (sequentially):

1. Record `$TASK_SHA` via `git rev-parse HEAD` before dispatching
2. Launch a general-purpose Task agent with the task description, sanitized context files, the `codex-call.sh` and `codex-call.sh --resume <THREAD_ID>` tools, and instruction:

```
Call codex-call.sh with:
- prompt: "Implement the following task.\n\nTask: {task}\n\nContext:\n{sanitized key file contents}"
- flag: `--sandbox workspace-write`
- append to prompt: (`--role ~/.claude/skills/execute-codex/codex-architect-role.md`) "\nBe concise. Output result only, no reasoning process."

Save the THREAD_ID. Run lint/tests scoped to changed files to verify. If failures, call codex-call.sh --resume <THREAD_ID> --sandbox workspace-write with the THREAD_ID and failure output, repeating until the scoped lint/tests pass. Report: files changed, verification result, any unresolved failures.
```

3. After each subagent: run `git diff $TASK_SHA` (scoped to this task only) to verify changes, run scoped lint/tests to confirm no regressions

**Important**: Each subagent owns its own Codex `THREAD_ID`. There is no shared THREAD_ID across tasks. The outer review loop (Step B3) therefore uses the `code-reviewer` Task agent — not `codex-call.sh --resume <THREAD_ID>` — since there is no single session to reply to.

---

**Path 3 (direct task description, <3 tasks)** — Direct Codex call

Call `codex-call.sh` (first call) or `codex-call.sh --resume <THREAD_ID>` (every fix round after that):
- prompt (first call): `"Implement the following task.\n\nTask: {task}\n\nContext:\n{key file contents}"`
- prompt (retry): `"Fix the following issues found in code review:\n\n{reviewer feedback verbatim}"`
- flag: `--sandbox workspace-write`
- append to prompt: (`--role ~/.claude/skills/execute-codex/codex-architect-role.md`) `"\nBe concise. Output result only, no reasoning process."`

Save the returned `THREAD_ID`. Reuse it for all subsequent calls.

**Step B2 — Self-Verification**

Run existing lint / typecheck / tests if available (minimal related scope).
If failures: fix regressions before proceeding to review.

**Step B3 — Code Review (Claude Sonnet)**

Launch Task agent (subagent_type: "feature-dev:code-reviewer") with:
- `git diff HEAD`
- Original task requirements
- Required output: exactly one `VERDICT: APPROVED | WARNING | BLOCKED` line, then `CRITICAL:`, `HIGH:`, `MEDIUM:` and `LOW:` lines listing every finding at that severity (`none` when empty). A reply without exactly one valid verdict line is a failed review: re-launch it.

Parse reviewer response:
- No findings at any severity → approved, go to Phase 3.
- Any finding at any severity → evaluate as below, fix, and re-review.

**Critical Evaluation** (before fixing): Critically evaluate each finding, at every severity:
- **Assess correctness**: Is it technically accurate? Check actual code and project conventions.
- **Check context**: Does the reviewer have full context, or is it flagging intentional design?
- **Verify applicability**: Does it improve correctness/security, or is it a style preference / false positive?
- **If a finding seems incorrect**: Do NOT fix it yet. Launch a new code-reviewer agent with the original diff, the contested findings, and your technical reasoning. Ask it to re-evaluate only the contested items. Keep every finding accepted unless that agent explicitly withdraws it in writing; your own disagreement never drops a finding.

After evaluation, every round with accepted findings (CRITICAL, HIGH, MEDIUM or LOW) applies the fixes and re-reviews:
- 3+ task path → dispatch a Claude subagent per affected task with the accepted reviewer feedback verbatim; there is no shared `THREAD_ID` to reply to, so do not call `codex-call.sh --resume <THREAD_ID>`.
- Single Codex session path → call `codex-call.sh --resume <THREAD_ID> --sandbox workspace-write` with the accepted reviewer feedback verbatim.
- Route B's no-Edit/Write rule holds either way. Verify with scoped lint/tests, then re-run `code-reviewer` on the new `git diff HEAD`.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved one for every later `--resume`; the CodeRabbit CLI has no thread and takes no prompt, so each follow-up is a fresh review of the new committed state, and a finding you contest is settled only by a Codex reviewer's explicit concession. Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do.

---

### Phase 3: Delivery

```markdown
## Execution Complete

### Changes
| File | Operation | Description |
|------|-----------|-------------|
| path/to/file | Modified | Description |

### Review Result
- Route: Small (Claude) / Large (Codex)
- Code review: clean after N rounds / N findings fixed, N dropped through discussion
- Remaining findings: none (the loop only ends on a clean round)

### Recommended Next Steps
1. [ ] <test step>
2. [ ] <verification step>
```
