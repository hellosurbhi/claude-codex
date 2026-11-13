---
description: "Codex implements (large), Claude implements (small), Sonnet reviews"
argument-hint: "<task description or path/to/plan.md>"
model: claude-sonnet-4-6
allowed-tools: ["AskUserQuestion", "Task", "Read", "Glob", "Grep", "Write", "Edit", "Bash"]
---

> **Deprecated**: This command has been converted to a skill (`/execute-codex`).
> The skill version is recommended for new usage and supports eval-based testing.
> This command is retained for backward compatibility (model pinning, tool restrictions).

# Execute-Codex — Smart Routing: Claude (small) / Codex (large)

$ARGUMENTS

---

## Core Protocols

- **Code Sovereignty**: Claude is the final authority — review and approve all changes before delivery
- **Stop-Loss**: Do not proceed to next phase until current phase output is validated
- **Language**: Use English when calling tools/models; communicate with user in their language
- **Context Sanitization**: Never pass `.env`, secrets, tokens, API keys, or credentials to any external agent or MCP. Exclude files matching `.env*`, `*secret*`, `*credential*`, `*.pem`, `*.key`. Redact inline secrets before sending.

---

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
3. Critically evaluate each finding at every severity (accuracy, reviewer context, preference or false positive); contest doubtful ones with a fresh code-reviewer agent and drop only findings the reviewer explicitly withdraws in writing; your own disagreement never drops a finding.
4. Any accepted finding at any severity (CRITICAL, HIGH, MEDIUM or LOW) → fix every accepted finding with Edit/Write in one batch, re-run self-verification, then re-run the code-reviewer from step 2 on the new `git diff HEAD`. Repeat until a round has no accepted findings. There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`; the CodeRabbit CLI has no thread and takes no prompt, so each follow-up is a fresh review of the new committed state, and a finding you contest is settled only by a Codex reviewer's explicit concession. Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do.
5. Go to Phase 3

---

### Route B: Large Change — Codex First (review until a round has no accepted findings; no iteration cap)

**MANDATORY**: When Route B is selected, you MUST NOT use Edit/Write tools for implementation. All implementation MUST go through `codex-call.sh`. Claude's role in Route B is context retrieval, verification, and review — not implementation. The ONLY exception is fixing minor regressions found during self-verification (Step B2) that are clearly caused by Codex output (e.g. a missing import, a typo in a generated file).

**No post-routing rationalization**: Once Route B is selected, the routing decision applies to ALL tasks in the plan. Do NOT re-evaluate individual tasks for complexity. If you find yourself thinking "this task is simple enough to do directly" or "this is just a deletion" — STOP. That is the routing decision being second-guessed. The routing already accounted for overall complexity. Every task goes through Codex.

**Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, fall back to Route A and announce: "Codex unavailable: falling back to Claude direct implementation." This fallback is ONLY for when Codex is technically unavailable (the wrapper or the CLI is missing). It MUST NOT be used because a task seems "too simple for Codex" or because Claude judges direct editing would be faster. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

**Note on agent spawning**: Codex runs in a sandboxed shell and cannot spawn Claude agents directly. Instead, Claude spawns a subagent per task — each subagent owns its Codex session for that task, keeping both the main context and each Codex session scoped and clean.

Read `~/.claude/prompts/codex/architect.md` and pass as `--role <file>` for all Codex calls.

**Step B1 — Dispatch per-task subagents (if plan has 3+ tasks)**

For each implementation task (sequentially):

1. Record `$TASK_SHA` via `git rev-parse HEAD` before dispatching
2. Launch a general-purpose Task agent with the task description, sanitized context files, the Bash tool (to run `codex-call.sh`), and instruction:

```
Call codex-call.sh with:
- prompt: "Implement the following task.\n\nTask: {task}\n\nContext:\n{sanitized key file contents}"
- flag: `--sandbox workspace-write`
- append to prompt: (`--role ~/.claude/prompts/codex/architect.md`) "\nBe concise. Output result only, no reasoning process."

Save the THREAD_ID. Run lint/tests scoped to changed files to verify. If failures, call codex-call.sh --resume <THREAD_ID> --sandbox workspace-write with the THREAD_ID and failure output, repeating until the scoped lint/tests pass. Report: files changed, verification result, any unresolved failures.
```

3. After each subagent: run `git diff $TASK_SHA` (scoped to this task only) to verify changes, run scoped lint/tests to confirm no regressions

**Important**: Each subagent owns its own Codex `THREAD_ID`. There is no shared THREAD_ID across tasks. The outer review loop (Step B3) therefore uses the `code-reviewer` Task agent — not `codex-call.sh --resume <THREAD_ID>` — since there is no single session to reply to.

**If plan has fewer than 3 tasks**, call Codex directly:

Call `codex-call.sh` (first call) or `codex-call.sh --resume <THREAD_ID>` (every fix round after that):
- prompt (first call): "Implement the following task.\n\nTask: {task}\n\nContext:\n{key file contents}"
- prompt (retry): "Fix the following issues found in code review:\n\n{reviewer feedback verbatim}"
- flag: `--sandbox workspace-write`
- append to prompt: (`--role ~/.claude/prompts/codex/architect.md`) "\nBe concise. Output result only, no reasoning process."

Save the returned `THREAD_ID`. Reuse it for all subsequent calls.

**Step B2 — Self-Verification**

Run existing lint / typecheck / tests if available (minimal related scope).
If failures: fix regressions before proceeding to review.

**Step B3 — Code Review (Claude Sonnet)**

Launch Task agent (subagent_type: "feature-dev:code-reviewer") with:
- `git diff HEAD`
- Original task requirements
- Required output: exactly one `VERDICT: APPROVED | WARNING | BLOCKED` line, then `CRITICAL:`, `HIGH:`, `MEDIUM:` and `LOW:` lines listing every finding at that severity (`none` when empty). A reply without exactly one valid verdict line is a failed review: re-launch it.

**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the actual code and project conventions, whether the reviewer had full context for intentional decisions and whether it improves correctness/security or is a preference / false positive. If a finding seems incorrect, launch a new code-reviewer agent with the original diff, the contested findings and your technical reasoning; accept every finding the reviewer does not explicitly withdraw in writing and drop only withdrawn ones; your own disagreement never drops a finding.

Parse reviewer response:
- No findings at any severity → approved, go to Phase 3.
- Any accepted finding at any severity (CRITICAL, HIGH, MEDIUM or LOW) → apply the fixes and re-review:
  - 3+ task path → dispatch a Claude subagent per affected task with the accepted reviewer feedback verbatim; there is no shared `THREAD_ID` to reply to, so do not call `codex-call.sh --resume <THREAD_ID>`.
  - Single Codex session path → call `codex-call.sh --resume <THREAD_ID> --sandbox workspace-write` with the accepted reviewer feedback verbatim.
  - Route B's no-Edit/Write rule holds either way. Verify with scoped lint/tests, then re-run `code-reviewer` on the new diff.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`; the CodeRabbit CLI has no thread and takes no prompt, so each follow-up is a fresh review of the new committed state, and a finding you contest is settled only by a Codex reviewer's explicit concession. Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do.

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
