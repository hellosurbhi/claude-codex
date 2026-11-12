---
description: "TDD workflow: Claude writes tests, Codex/Claude implements, Claude reviews"
argument-hint: "<task description or path/to/plan.md>"
model: claude-sonnet-4-6
allowed-tools: ["AskUserQuestion", "Task", "Read", "Glob", "Grep", "Write", "Edit", "Bash"]
---

> **Deprecated**: This command has been converted to a skill (`/tdd-execute-codex`).
> The skill version is recommended for new usage and supports eval-based testing.
> This command is retained for backward compatibility (model pinning, tool restrictions).

# TDD-Execute-Codex — Tests First, Smart Routing, Claude Reviews

$ARGUMENTS

---

## Core Protocols

- **TDD Mandate**: Tests must be written and verified RED before any implementation begins
- **Code Sovereignty**: Claude is the final authority — review and approve all changes before delivery
- **Stop-Loss**: Do not proceed to next phase until current phase output is validated
- **Language**: Use English when calling tools/models; communicate with user in their language
- **Test Ownership**: Claude owns all test files. Codex never modifies test files.
- **Context Sanitization**: Never pass `.env`, secrets, tokens, API keys, or credentials to any external agent or MCP. Exclude files matching `.env*`, `*secret*`, `*credential*`, `*.pem`, `*.key`. Redact inline secrets before sending.

---

## Execution Workflow

### Phase 0: Read Plan

1. If argument is a file path, read it and extract: task description, implementation steps, key files
2. If no plan file, use the argument as the task description directly
3. Confirm with user before proceeding if key context is missing

### Phase 1: Context Retrieval

1. Read key files using Read, Glob, Grep (sanitize before passing to agents)
2. Identify existing test framework, patterns, test file conventions, and configuration
3. Establish test baseline:
   - Fast suite (<2 min): run the full suite, record pass/fail counts
   - Slow suite (>2 min) or partially failing: run only tests related to the task scope, record known failures
   - No test suite: skip — note "no baseline available", regression detection relies on new tests only
4. Record `$START_SHA` via `git rev-parse HEAD` for diff scoping
5. If worktree is dirty (uncommitted changes), stop and ask the user to commit or stash their changes before running this command. Do not proceed with a dirty worktree.

### Phase 2: TDD — Write Tests First (RED)

**Constraint**: This phase outputs test files only. No production code, no interface stubs, no implementation scaffolds. Types/interfaces needed by tests must be defined inline within the test file or use `any`/equivalent.

Read `tdd-specialist-role.md` from the `skills/tdd-execute-codex/` directory.

Launch a general-purpose Task agent with:
- Task description
- Sanitized key file contents for context
- Existing test patterns/framework info
- Content of tdd-specialist-role.md as the agent's role context
- Instruction: "Write failing test files ONLY. Do NOT create any production code, interfaces, or stubs. Define any needed types inline within test files. Follow RED phase only."

Apply the returned test files using Write/Edit.

**RED Verification (scoped — run new tests only, not the full suite)**:
- Run ONLY the newly created test files
- Verify they fail for the expected reason ("module not found", "not implemented", assertion failure on missing behavior)
- If tests pass unexpectedly → tests are wrong; revise and re-verify RED
- If tests fail for wrong reasons (syntax errors, broken imports unrelated to missing implementation) → fix the test file, re-run

### Phase 3: Codex Test Audit (re-audit until a round has no accepted findings at any severity; no iteration cap)

**MANDATORY Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. Do NOT skip or bypass this phase and do NOT assume Codex is unavailable without running the check. If both pass, use Codex, no exceptions. If either fails, note "Codex unavailable: test audit skipped, the tests are UNREVIEWED" and proceed to Phase 4. Carry that line into the delivery report; never report a skipped audit as approved. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

Before implementing, have Codex review the tests for quality, completeness, and edge case coverage.

Run `git add -N .` to mark new test files as intent-to-add.

**Call `codex-call.sh`** (iteration 1):
- append to prompt: `"Be concise. Return only the structured verdict format. No prose."`
- `prompt`:

```
Run `git diff $START_SHA` to see newly created test files. Review the tests ONLY (no implementation exists yet).

Evaluate:
1. Do the tests cover the described task requirements comprehensively?
2. Are edge cases covered (null, empty, boundary, error paths)?
3. Are tests well-structured and following project test conventions?
4. Are there any tests that are impossible to implement or fundamentally flawed?

Return ONLY a structured verdict:

VERDICT: APPROVED | WARNING | BLOCKED

CRITICAL: <list or 'none'>
HIGH: <list or 'none'>
MEDIUM: <list or 'none'>
LOW: <list or 'none'>
```

Save the returned `THREAD_ID` (separate from the implementation review THREAD_ID).

**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the test code and project test conventions, whether the reviewer had full context on the testing strategy and requirements and whether it improves test quality or is a preference / false positive. Contest doubtful findings via `codex-call.sh --resume <THREAD_ID>` with specific reasoning; discussion replies do not count as iterations. Only findings that survive this gate are "accepted" below.

**Parse response**: every verdict is handled the same way: the severity of a finding decides how urgent it is, never whether it gets fixed.
- **Any accepted finding at any severity** (BLOCKED, WARNING, or APPROVED with MEDIUM/LOW findings listed) → Claude fixes every accepted finding in the test files, re-verifies RED, then re-audits via `codex-call.sh --resume <THREAD_ID>`.
- **Done** → a round that lists no findings, or whose every finding was dropped through the evaluation gate. Only then proceed to Phase 4.
- **Failed audit** (error, timeout or no verdict) → retry once; if it fails again, report "test audit incomplete, the tests are UNREVIEWED" in the delivery report and proceed to Phase 4. Never report it as approved.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict is NOT an approval: retry it once, and if it fails again stop and tell the user the changes are UNREVIEWED.

### Phase 4: Route by Change Size

**IMPORTANT**: Routing is based on estimated **implementation** scope only. Exclude test files written in Phase 2 from the size calculation. Evaluate only the production code that needs to be written/modified.

**Small change** — ALL of the following must be true:
- Touches ≤ 2 production files
- Estimated implementation diff ≤ 30 lines
- No new abstractions, modules, or significant logic

**Large change** — any of the following:
- Touches 3+ production files
- Implementation diff > 30 lines
- Introduces new logic, new files, refactoring, or cross-cutting concerns

Announce routing decision (e.g. "Small change — implementing directly" or "Large change — routing to Codex").

---

### Route A: Small Change — Claude Implements (GREEN)

**If the plan has 3+ implementation tasks**, dispatch each task to a subagent (sequentially):
- Before each task: record `$TASK_SHA` via `git rev-parse HEAD`
- For each task: launch a general-purpose Task agent with the task description, relevant test files it must pass, sanitized context files, and instruction: "Implement only this task. Make the provided tests pass. Do not modify test files. Run tests and confirm GREEN before finishing. Report: files changed, test result, any blockers."
- After each subagent: run `git diff $TASK_SHA` (scoped to this task only) to verify changes, run the task's tests to confirm GREEN
- If the subagent reports a blocker: fix directly with Edit/Write or re-dispatch with failure output

**If fewer than 3 tasks**: implement directly with Edit/Write.

After all tasks complete (either path):
1. Run new tests — verify GREEN
2. Run baseline test scope — verify no new regressions
3. Refactor while keeping tests green
4. If coverage tooling available: check coverage (80%+)
5. Exception — if tests are fundamentally wrong: revise with justification, re-verify RED, re-implement
6. Run `git add -N .` to mark any new untracked files as intent-to-add (ensures `git diff $START_SHA` includes new files)
7. Launch Task agent (subagent_type: "feature-dev:code-reviewer") with:
   - `git diff $START_SHA` output
   - Original task requirements
8. **Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the actual code and project conventions, whether the reviewer had full context for intentional decisions and whether it improves correctness/security or is a preference / false positive. If a finding seems incorrect, launch a new code-reviewer agent with the original diff, the contested findings and your technical reasoning; accept confirmed findings, drop withdrawn ones. Discussion rounds do NOT count as review rounds. Then: any accepted finding at any severity (CRITICAL, HIGH, MEDIUM or LOW) → fix every accepted finding with Edit/Write, re-run the test suite (must stay GREEN), run `git add -N .`, and re-run the code-reviewer from step 7 on the new `git diff $START_SHA`.
9. Repeat steps 7 and 8 until a round has no accepted findings. There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict is NOT an approval: retry it once, and if it fails again stop and tell the user the changes are UNREVIEWED.
10. Go to Phase 5

---

### Route B: Large Change — Codex Implements (GREEN; review until a round has no accepted findings, no iteration cap)

**MANDATORY**: When Route B is selected, you MUST NOT use Edit/Write tools for implementation. All implementation MUST go through `codex-call.sh`. Claude's role in Route B is context retrieval, test ownership, verification, and review — not implementation. The ONLY exception is fixing minor regressions found during self-verification (Step B2) that are clearly caused by Codex output (e.g. a missing import, a typo in a generated file).

**No post-routing rationalization**: Once Route B is selected, the routing decision applies to ALL tasks in the plan. Do NOT re-evaluate individual tasks for complexity. If you find yourself thinking "this task is simple enough to do directly" or "this is just a deletion" — STOP. That is the routing decision being second-guessed. The routing already accounted for overall complexity. Every task goes through Codex.

**Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, fall back to Route A and announce: "Codex unavailable: falling back to Claude direct implementation." This fallback is ONLY for when Codex is technically unavailable (the wrapper or the CLI is missing). It MUST NOT be used because a task seems "too simple for Codex" or because Claude judges direct editing would be faster. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

**Note on agent spawning**: Codex runs in a sandboxed shell and cannot spawn Claude agents directly. Instead, Claude spawns a subagent per task — each subagent owns its Codex session for that task, keeping both the main context and each Codex session scoped and clean.

**Step B1 — Dispatch per-task subagents (if plan has 3+ tasks)**

For each implementation task (sequentially — next starts only after current passes tests):

1. Record `$TASK_SHA` via `git rev-parse HEAD` before dispatching
2. Launch a general-purpose Task agent with:
   - The specific task description
   - Relevant test file contents (tests it must pass)
   - Sanitized key file contents
   - The `codex-call.sh` and `codex-call.sh --resume <THREAD_ID>` tools
   - Instruction:

```
You are implementing one task using Codex via codex-call.sh. Follow these steps:

1. Call codex-call.sh with:
   - prompt: "Implement the following task. Tests are pre-written — make them pass.\n\nTask: {task}\n\nTest files:\n{test file contents}\n\nContext:\n{sanitized key file contents}"
   - flag: `--sandbox workspace-write`
   - append to prompt: (`--role ~/.claude/prompts/codex/architect.md`) "\nTests are pre-written. Write minimal implementation to pass all tests. Do not modify test files."

2. Save the returned THREAD_ID.

3. Run the task's tests to verify GREEN.

4. If tests fail: call codex-call.sh --resume <THREAD_ID> --sandbox workspace-write with the THREAD_ID and failure output. Repeat until the task's tests pass.

5. Report back: files changed, final test result, any unresolved failures.
```

3. After each subagent: run `git diff $TASK_SHA` (scoped to this task only) to verify what changed, run the task's tests to confirm GREEN

**Important**: Each subagent owns its own Codex `THREAD_ID`. There is no shared THREAD_ID across tasks. Step B4 (code review) therefore uses the `code-reviewer` Task agent — not `codex-call.sh --resume <THREAD_ID>` — since there is no single session to reply to.

**If plan has fewer than 3 tasks**, call `codex-call.sh` directly (first call) or `codex-call.sh --resume <THREAD_ID>` (every fix round after that):
- prompt: "Implement the following task. Tests have already been written — your implementation must make all tests pass.\n\nTask: {task}\n\nTest files:\n{test file contents}\n\nContext:\n{sanitized key file contents}"
- prompt (retry): "Fix the following issues:\n\n{failure output or reviewer feedback verbatim}"
- flag: `--sandbox workspace-write`
- append to prompt: (`--role ~/.claude/prompts/codex/architect.md`) "\nTests are pre-written. Write minimal implementation to pass all tests. Do not modify test files."

Save the returned `THREAD_ID`. Reuse for all subsequent calls.

**Step B2 — Run Tests**

Run new tests to verify GREEN. Run baseline test scope to verify no new regressions.
If failures: include failure output verbatim in the next Codex iteration prompt.

**Step B3 — Coverage Check and Test Corrections (Claude owns)**

Check coverage if tooling is available (target 80%+). If unavailable, skip and note in delivery.

**Claude owns all post-RED test changes.** Codex never modifies test files. If additional tests are needed or existing tests need correction:
- Add coverage tests: write new test cases using Edit/Write, run to verify RED, then verify Codex's implementation passes them
- Correct bad tests: revise with explicit justification using Edit/Write, re-verify RED, then re-verify GREEN
- After any test changes: re-run the full new test suite to confirm GREEN before proceeding

**Step B4 — Code Review (Claude)**

Run `git add -N .` to mark any new untracked files as intent-to-add (ensures `git diff $START_SHA` includes new files).

Launch Task agent (subagent_type: "feature-dev:code-reviewer") with:
- `git diff $START_SHA` output
- Original task requirements

**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the actual code and project conventions, whether the reviewer had full context for intentional decisions and whether it improves correctness/security or is a preference / false positive. If a finding seems incorrect, launch a new code-reviewer agent with the original diff, the contested findings and your technical reasoning; accept confirmed findings, drop withdrawn ones. Discussion rounds do NOT count as review rounds.

Parse reviewer response:
- No findings at any severity → approved, go to Phase 5.
- Any accepted finding at any severity (CRITICAL, HIGH, MEDIUM or LOW) → apply the fixes and re-review:
  - 3+ task path → dispatch a Claude subagent per affected task with the accepted reviewer feedback verbatim; there is no shared `THREAD_ID` to reply to, so do not call `codex-call.sh --resume <THREAD_ID>`.
  - Single Codex session path → call `codex-call.sh --resume <THREAD_ID> --sandbox workspace-write` with the accepted reviewer feedback verbatim.
  - Route B's no-Edit/Write rule holds either way. Verify with the test suite (must stay GREEN) and run `git add -N .`, then re-run `code-reviewer` on the new diff.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict is NOT an approval: retry it once, and if it fails again stop and tell the user the changes are UNREVIEWED.

---

### Phase 5: Delivery

```markdown
## Execution Complete

### Changes
| File | Operation | Description |
|------|-----------|-------------|
| path/to/file | Created/Modified | Description |

### TDD Summary
- Tests written: N test files, M test cases
- Coverage: X% (target: 80%) / not measured (no coverage tooling)
- RED phase: All new tests failed as expected
- GREEN phase: All tests passing, no regressions

### Review Result
- Codex test audit: clean after N rounds / UNREVIEWED (audit skipped or failed)
- Route: Small (Claude) / Large (Codex)
- Code review: clean after N rounds / N findings fixed, N dropped through discussion
- Remaining findings: none (the loop only ends on a clean round)

### Recommended Next Steps
1. [ ] Run full test suite
2. [ ] Verify coverage meets project standards
```
