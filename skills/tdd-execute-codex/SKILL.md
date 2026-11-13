---
name: tdd-execute-codex
description: "Full TDD with smart routing: Claude writes tests first, Codex audits tests, then routes implementation by size (Claude small / Codex large), code-reviewer reviews. Best for: TDD on larger tasks where Codex should handle heavy implementation. Triggers on: /tdd-execute-codex, TDD with routing, test-driven execute, TDD large feature."
---

# TDD-Execute-Codex — Tests First, Smart Routing, Claude Reviews

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
- `Bash` running `~/.claude/config/scripts/codex-call.sh` (wraps `codex exec`; follow-ups use `--resume THREAD_ID`) — Codex test audit and Route B implementation
- `Task` — dispatch subagents (tdd-guide, code-reviewer, general-purpose)
- `Read`, `Glob`, `Grep` — context retrieval
- `Write`, `Edit` — write tests and implement (Route A)
- `Bash` — run tests/lint/git commands

## Core Protocols

- **TDD Mandate**: Tests must be written and verified RED before any implementation begins
- **Code Sovereignty**: Claude is the final authority — review and approve all changes before delivery
- **Stop-Loss**: Do not proceed to next phase until current phase output is validated
- **Language**: Use English when calling tools/models; communicate with user in their language
- **Test Ownership**: Claude owns all test files. Codex never modifies test files.
- **Context Sanitization**: Never pass `.env`, secrets, tokens, API keys, or credentials to any external agent or MCP. Exclude files matching `.env*`, `*secret*`, `*credential*`, `*.pem`, `*.key`. Redact inline secrets before sending.

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
5. If worktree is dirty (uncommitted changes), stop and ask the user to commit or stash their changes before running this skill. Do not proceed with a dirty worktree.

### Phase 2: TDD — Write Tests First (RED)

**Constraint**: This phase outputs test files only. No production code, no interface stubs, no implementation scaffolds. Types/interfaces needed by tests must be defined inline within the test file or use `any`/equivalent.

Read `tdd-specialist-role.md` from this skill directory.

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

**Failed audit**: a Codex call that errors, times out, exits without a final message (`codex-call.sh` exits non-zero with "UNREVIEWED") or replies without exactly one valid `VERDICT:` line (APPROVED, WARNING or BLOCKED) is NOT an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved one for every later `--resume`; the CodeRabbit CLI has no thread, so each follow-up is a fresh review of the new state with any contested finding argued in the prompt. Stop and report "test audit incomplete, the tests are UNREVIEWED: <blocker>" only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do. Phase 4 starts only after a clean audit, or after that named blocker with the tests labeled UNREVIEWED in the delivery report and in your final message.

**Parse response**: every verdict is handled the same way: the severity of a finding decides how urgent it is, never whether it gets fixed.
- **Any findings at any severity** (BLOCKED, WARNING, or APPROVED with MEDIUM/LOW findings listed) → critically evaluate each one (see below), fix the accepted ones in the test files, re-verify RED, and re-audit.
- **Done** → a round that lists no findings, or whose every finding was dropped through the discussion path below. Only then proceed to Phase 4.

**Critical Evaluation of Test Audit Findings**

Before fixing any issues, critically evaluate each finding, at every severity:

1. **Assess correctness**: Is the finding technically accurate? Check the test code and project test conventions.
2. **Check context**: Does the reviewer have full context about the testing strategy and requirements?
3. **Verify applicability**: Does the suggestion improve test quality, or is it a preference / false positive?

**If a finding seems incorrect or questionable:**
- Do NOT fix it yet. Instead, reply to the reviewer with your technical reasoning.
- Call `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) explaining why the finding appears incorrect, with specific test code references.
- If the reviewer provides additional justification that is convincing, accept the finding.
- Drop the finding only when the reviewer explicitly concedes it in writing. If it maintains the finding or gives no clear answer, accept it and fix it; your own disagreement never drops a finding.
- A discussion reply never ends the loop by itself: the loop ends only when a round has no accepted findings.

**If findings are accepted:** Claude fixes every accepted finding (CRITICAL, HIGH, MEDIUM or LOW) in the test files, re-verifies RED, and re-calls `codex-call.sh --resume <THREAD_ID>` to re-audit.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved one for every later `--resume`; the CodeRabbit CLI has no thread, so each follow-up is a fresh review of the new state with any contested finding argued in the prompt. Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do.

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
   - Required output: exactly one `VERDICT: APPROVED | WARNING | BLOCKED` line, then `CRITICAL:`, `HIGH:`, `MEDIUM:` and `LOW:` lines listing every finding at that severity (`none` when empty). A reply without exactly one valid verdict line is a failed review: re-launch it.
8. **Critical Evaluation**: Before fixing, critically evaluate each finding, at every severity:
   - **Assess correctness**: Is it technically accurate? Check actual code and project conventions.
   - **Check context**: Does the reviewer have full context, or is it flagging intentional design?
   - **Verify applicability**: Does it improve correctness/security, or is it a style preference / false positive?
   - **If a finding seems incorrect**: Do NOT fix it yet. Launch a new code-reviewer agent with the original diff, the contested findings, and your technical reasoning. Ask it to re-evaluate only the contested items. Keep every finding accepted unless that agent explicitly withdraws it in writing; your own disagreement never drops a finding.
9. Any accepted finding at any severity (CRITICAL, HIGH, MEDIUM or LOW) → fix every accepted finding in one batch with Edit/Write, re-run the full test suite (must stay GREEN), run `git add -N .`, then re-run the code-reviewer from step 7 on the new `git diff $START_SHA`.
10. Repeat steps 7 to 9 until a round has no accepted findings. There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved one for every later `--resume`; the CodeRabbit CLI has no thread, so each follow-up is a fresh review of the new state with any contested finding argued in the prompt. Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do.
11. Go to Phase 5

---

### Route B: Large Change — Codex Implements (GREEN; review until a round has no accepted findings, no iteration cap)

**MANDATORY**: When Route B is selected, you MUST NOT use Edit/Write tools for implementation. All implementation MUST go through `codex-call.sh`. Claude's role in Route B is context retrieval, test ownership, verification, and review — not implementation. The ONLY exception is fixing minor regressions found during self-verification (Step B2) that are clearly caused by Codex output (e.g. a missing import, a typo in a generated file).

**No post-routing rationalization**: Once Route B is selected, the routing decision applies to ALL tasks in the plan. Do NOT re-evaluate individual tasks for complexity. If you find yourself thinking "this task is simple enough to do directly" or "this is just a deletion" — STOP. That is the routing decision being second-guessed. The routing already accounted for overall complexity. Every task goes through Codex.

**Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, fall back to Route A and announce: "Codex unavailable: falling back to Claude direct implementation." This fallback is ONLY for when Codex is technically unavailable (the wrapper or the CLI is missing). It MUST NOT be used because a task seems "too simple for Codex" or because Claude judges direct editing would be faster. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

Pass the installed path `~/.claude/skills/tdd-execute-codex/codex-architect-role.md` as `--role` (an absolute path: a bare filename is read relative to the project directory) for all Codex calls.

**Step B1 — Dispatch to Codex**

Choose the path based on how the task was provided in Phase 0:

---

**Path 1 (plan file input)** — Pass plan file to Codex; Codex uses agents for parallel execution

When the input was a plan file path, make a single Codex call with the plan file path. Codex reads the plan, identifies task dependencies, and spawns sub-agents to run independent tasks in parallel. Claude owns all test files — instruct Codex never to modify them.

Call `codex-call.sh`:
- prompt: `"Read the plan file at \`{plan_file_path}\`. Tests have already been written by Claude — your implementation must make them pass. Do NOT modify any test files.\n\nFor implementation tasks with no shared file conflicts or ordering dependencies, use sub-agents to run them in parallel. For dependent tasks, execute sequentially after prerequisites complete.\n\nTest files written:\n{list of test file paths from Phase 2}"`
- flag: `--sandbox workspace-write`
- append to prompt: (`--role ~/.claude/skills/tdd-execute-codex/codex-architect-role.md`) `"\nTests are pre-written. Write minimal implementation to pass all tests. Do not modify test files. Be concise. Output result only, no reasoning process."`

Save the returned `THREAD_ID`. Proceed to Step B2.

---

**Path 2 (direct task description, 3+ tasks)** — Claude dispatches per-task subagents sequentially

**Note on agent spawning**: Codex runs in a sandboxed shell and cannot spawn Claude agents directly. For direct task descriptions with 3+ tasks, Claude spawns a subagent per task — each subagent owns its Codex thread (its own `THREAD_ID`) for that task, keeping both the main context and each Codex session scoped and clean.

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
   - append to prompt: (`--role ~/.claude/skills/tdd-execute-codex/codex-architect-role.md`) "\nTests are pre-written. Write minimal implementation to pass all tests. Do not modify test files."

2. Save the returned THREAD_ID.

3. Run the task's tests to verify GREEN.

4. If tests fail: call codex-call.sh --resume <THREAD_ID> --sandbox workspace-write with the THREAD_ID and failure output. Repeat until the task's tests pass.

5. Report back: files changed, final test result, any unresolved failures.
```

3. After each subagent: run `git diff $TASK_SHA` (scoped to this task only) to verify what changed, run the task's tests to confirm GREEN

**Important**: Each subagent owns its own Codex `THREAD_ID`. There is no shared THREAD_ID across tasks. Step B4 (code review) therefore uses the `code-reviewer` Task agent — not `codex-call.sh --resume <THREAD_ID>` — since there is no single session to reply to.

---

**Path 3 (direct task description, <3 tasks)** — Direct Codex call

Call `codex-call.sh` (first call) or `codex-call.sh --resume <THREAD_ID>` (every fix round after that):
- prompt: `"Implement the following task. Tests have already been written — your implementation must make all tests pass.\n\nTask: {task}\n\nTest files:\n{test file contents}\n\nContext:\n{sanitized key file contents}"`
- prompt (retry): `"Fix the following issues:\n\n{failure output or reviewer feedback verbatim}"`
- flag: `--sandbox workspace-write`
- append to prompt: (`--role ~/.claude/skills/tdd-execute-codex/codex-architect-role.md`) `"\nTests are pre-written. Write minimal implementation to pass all tests. Do not modify test files."`

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
- Required output: exactly one `VERDICT: APPROVED | WARNING | BLOCKED` line, then `CRITICAL:`, `HIGH:`, `MEDIUM:` and `LOW:` lines listing every finding at that severity (`none` when empty). A reply without exactly one valid verdict line is a failed review: re-launch it.

Parse reviewer response:
- No findings at any severity → approved, go to Phase 5.
- Any finding at any severity → evaluate as below, fix, and re-review.

**Critical Evaluation** (before fixing): Critically evaluate each finding, at every severity:
- **Assess correctness**: Is it technically accurate? Check actual code and project conventions.
- **Check context**: Does the reviewer have full context, or is it flagging intentional design?
- **Verify applicability**: Does it improve correctness/security, or is it a style preference / false positive?
- **If a finding seems incorrect**: Do NOT fix it yet. Launch a new code-reviewer agent with the original diff, the contested findings, and your technical reasoning. Ask it to re-evaluate only the contested items. Keep every finding accepted unless that agent explicitly withdraws it in writing; your own disagreement never drops a finding.

After evaluation, every round with accepted findings (CRITICAL, HIGH, MEDIUM or LOW) applies the fixes and re-reviews:
- 3+ task path → dispatch a Claude subagent per affected task with the accepted reviewer feedback verbatim; there is no shared `THREAD_ID` to reply to, so do not call `codex-call.sh --resume <THREAD_ID>`.
- Single Codex session path → call `codex-call.sh --resume <THREAD_ID> --sandbox workspace-write` with the accepted reviewer feedback verbatim.
- Route B's no-Edit/Write rule holds either way. Verify with the test suite (must stay GREEN), run `git add -N .`, then re-run `code-reviewer` on the new `git diff $START_SHA`.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved one for every later `--resume`; the CodeRabbit CLI has no thread, so each follow-up is a fresh review of the new state with any contested finding argued in the prompt. Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do.

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
