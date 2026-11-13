---
name: tdd-claude-codex
description: "Full TDD workflow: Claude writes tests first (RED), Codex audits tests, Claude implements (GREEN), refactors (IMPROVE), Codex reviews final implementation. Best for: test-driven development where you want Codex reviewing both tests and code. Triggers on: /tdd-claude-codex, TDD with review, test-driven implement, tests first then implement."
---

# TDD-Claude-Codex — Tests First, Claude Implements, Codex Reviews

## Input

The user's message after the trigger is either:
1. A file path to a plan (e.g. `.claude/plan/feature.md`) — read it and extract task description, implementation steps, key files
2. A direct task description — use as-is

Confirm with user before proceeding if key context is missing.

## Model Recommendation

Works with `claude-sonnet-4-6` (default). Override with `/model opus` for tasks requiring deep architectural reasoning.

## Tool Requirements

Advisory checklist — ensure these tools are available:
- `AskUserQuestion` — confirm missing context
- `Task` — dispatch tdd-guide and implementation subagents
- `Read`, `Glob`, `Grep` — context retrieval
- `Write`, `Edit` — write tests and implement
- `Bash` — run tests/lint/git commands
- `Bash` running `~/.claude/config/scripts/codex-call.sh` (wraps `codex exec`; follow-ups use `--resume THREAD_ID`) — Codex test audit and implementation review

## Core Protocols

- **TDD Mandate**: Tests must be written and verified RED before any implementation begins
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

**MANDATORY Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, **degrade gracefully**: note "Codex unavailable: test audit skipped, the tests are UNREVIEWED" and proceed to Phase 4. Carry that line into the delivery report; never report a skipped audit as approved. Do not stop; implementation can continue without the test audit. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

Before implementing, have Codex review the tests for quality, completeness, and edge case coverage.

Run `git add -N .` to mark new test files as intent-to-add.

Pass the installed path `~/.claude/skills/tdd-claude-codex/codex-analyzer-role.md` as `--role` (an absolute path: a bare filename is read relative to the project directory).

**Call `codex-call.sh`** (iteration 1):
- append to prompt: (`--role ~/.claude/skills/tdd-claude-codex/codex-analyzer-role.md`) `"\nBe concise. Return only the structured verdict format. No prose."`
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

### Phase 4: Claude Implements (GREEN)

**If the plan has 3+ implementation tasks**, dispatch each task to a subagent to keep the main context clean:

For each task (sequentially — next task starts only after current task passes tests):
1. Record `$TASK_SHA` via `git rev-parse HEAD` before dispatching
2. Launch a general-purpose Task agent with:
   - The specific task description and acceptance criteria
   - Relevant test file contents (the tests it must pass)
   - Sanitized key file contents it needs to read/modify
   - Instruction: "Implement only this task. Make the provided tests pass. Do not modify test files. Run the tests and confirm GREEN before finishing. Report: files changed, test result, any blockers."
3. After the subagent completes: run `git diff $TASK_SHA` (scoped to this task only) to verify what changed, run the task's tests to confirm GREEN
4. If the subagent reports a blocker or tests are still failing: fix directly with Edit/Write or re-dispatch with the failure output

**If the plan has fewer than 3 tasks**, implement directly:
- Write minimal implementation to make all new tests pass
- Run the new test files — verify all pass

After all tasks complete (either path):
- Run the baseline test scope — verify no new regressions (pre-existing failures are not regressions)
- Exception — if tests are fundamentally wrong (impossible behavior, flaky by design): revise tests with explicit justification, re-verify RED, then re-implement

### Phase 5: Refactor (IMPROVE)

- Refactor implementation while keeping tests green
- Run tests after refactoring to confirm no regressions
- If coverage tooling is available: check coverage (target 80%+); add tests if below threshold
- If coverage tooling is not available: skip and note "coverage not measured" in delivery

### Phase 6: Codex Review (re-review until a round has no accepted findings at any severity; no iteration cap)

**MANDATORY Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, **stop and tell the user**: "Codex CLI or codex-call.sh is not available. This skill requires Codex." Do NOT skip or bypass this phase. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.)

**Step R1 — Run Codex Review via codex-call.sh**

Before calling Codex, run `git add -N .` to mark any new untracked files as intent-to-add. This ensures `git diff $START_SHA` shows all created files, not just modifications.

Call `codex-call.sh` with:
- append to prompt: `"Be concise. Return only the structured verdict format. No prose."`
- `prompt`:

```
Run `git diff $START_SHA` to see all changes made during this session, then review them.

Return ONLY a structured verdict in this exact format — no explanations, no prose:

VERDICT: APPROVED | WARNING | BLOCKED

CRITICAL: <list or 'none'>
HIGH: <list or 'none'>
MEDIUM: <list or 'none'>
LOW: <list or 'none'>
```

Save the returned `THREAD_ID` for follow-up replies.

**Failed review**: a Codex call that errors, times out, exits without a final message (`codex-call.sh` exits non-zero with "UNREVIEWED") or replies without exactly one valid `VERDICT:` line (APPROVED, WARNING or BLOCKED) is NOT an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved one for every later `--resume`; the CodeRabbit CLI has no thread, so each follow-up is a fresh review of the new state with any contested finding argued in the prompt. Stop and tell the user: "Codex review incomplete. The changes are UNREVIEWED: <blocker>." only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do. Never deliver the changes as reviewed.

Classify the verdict. Every verdict is handled the same way: the severity of a finding decides how urgent it is, never whether it gets fixed.
- **Any findings at any severity** (BLOCKED, WARNING, or APPROVED with MEDIUM/LOW findings listed) → critically evaluate each one (R1.5), then fix and re-review (R2).
- **Done** → a round that lists no findings (`none` on every severity line), or whose every finding was dropped through the R1.5 discussion path. Only then go to Phase 7.

**Step R1.5 — Critical Evaluation of Review Findings**

Before fixing any issues, critically evaluate each finding, at every severity:

1. **Assess correctness**: Is the finding technically accurate? Check the actual code and project conventions.
2. **Check context**: Does the reviewer have full context, or is it flagging intentional design decisions?
3. **Verify applicability**: Does the suggestion improve correctness/security, or is it a style preference / false positive?

**If a finding seems incorrect or questionable:**
- Do NOT fix it yet. Instead, reply to the reviewer with your technical reasoning.
- Call `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) explaining why the finding appears incorrect, with specific code references.
- If the reviewer provides additional justification that is convincing, accept the finding and include it in the fix batch.
- Drop the finding only when the reviewer explicitly concedes it in writing. If it maintains the finding or gives no clear answer, accept it and fix it; your own disagreement never drops a finding.
- A discussion reply never ends the loop by itself: the loop ends only when a round has no accepted findings.

**If all findings appear correct:** proceed directly to Step R2.

**Step R2 — Fix and Re-review (every round with accepted findings)**

Address ALL accepted findings before re-reviewing:
- Collect every accepted CRITICAL, HIGH, MEDIUM and LOW finding from the last review
- Fix them all with Edit/Write in one batch
- Run the test suite (all tests must stay GREEN) and lint to verify
- Re-call Codex via `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) with:

```
Run `git diff $START_SHA` again to see the updated changes, then re-review.

Return ONLY the structured verdict in the same format.
```

One review per round, not one review per fix.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry, or switch to another independent reviewer (a fresh Codex thread without `--resume`, or for committed changes the CodeRabbit CLI via `REVIEW_BASE_SHA=<base commit> ~/.claude/config/scripts/reviewer.sh R <diff-file> <out-file>`). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved one for every later `--resume`; the CodeRabbit CLI has no thread, so each follow-up is a fresh review of the new state with any contested finding argued in the prompt. Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do.

### Phase 7: Delivery

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
- Implemented by: Claude (active model)
- Codex implementation review: clean after N rounds / N findings fixed, N dropped through discussion
- Remaining findings: none (the loop only ends on a clean round)

### Recommended Next Steps
1. [ ] Run full test suite
2. [ ] Verify coverage meets project standards
```
