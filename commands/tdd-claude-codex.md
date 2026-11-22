---
description: "TDD workflow: Claude writes tests first, implements, Codex reviews"
argument-hint: "<task description or path/to/plan.md>"
model: claude-sonnet-4-6
allowed-tools: ["AskUserQuestion", "Task", "Read", "Glob", "Grep", "Write", "Edit", "Bash"]
---

> **Deprecated**: This command has been converted to a skill (`/tdd-claude-codex`).
> The skill version is recommended for new usage and supports eval-based testing.
> This command is retained for backward compatibility (model pinning, tool restrictions).

# TDD-Claude-Codex — Tests First, Claude Implements, Codex Reviews

$ARGUMENTS

---

## Core Protocols

- **TDD Mandate**: Tests must be written and verified RED before any implementation begins
- **Sovereignty**: Claude implements; Codex is the external reviewer — do not skip review
- **Stop-Loss**: Do not proceed to the next phase until the current phase output is validated
- **Language**: Use English when calling tools/models; communicate with user in their language
- **Wrapper for review**: Always call Codex review via `codex-call.sh`. Do NOT use bare `codex review`: it produces verbose output that wastes tokens.
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

Read `tdd-specialist-role.md` from the `skills/tdd-claude-codex/` directory.

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

Before implementing, have Codex review the tests for quality, completeness, and edge case coverage.

Before the audit, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`).

**Call `codex-call.sh`** (iteration 1):
- append to prompt: `"Be concise. Return only the structured verdict format. No prose."`
- `prompt`:

```
Run `git diff $START_SHA -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'` to see newly created test files. Review the tests ONLY (no implementation exists yet).

Task requirements (paste the task text or the saved task path content here, with any secret, credential or `.env` value removed first):
<TASK_REQUIREMENTS>

Evaluate:
1. Do the tests cover the task requirements above comprehensively?
2. Are edge cases covered (null, empty, boundary, error paths)?
3. Are tests well-structured and following project test conventions?
4. Are there any tests that are impossible to implement or fundamentally flawed?

Return ONLY a structured verdict:

VERDICT: APPROVED | WARNING | BLOCKED

CRITICAL: <findings>
HIGH: <findings>
MEDIUM: <findings>
LOW: <findings>

Omit any severity line with no findings (never write placeholder lines such as "HIGH: none", and never a severity header with no text after it). A clean review is exactly the one line `VERDICT: APPROVED`.
```

Save the returned `THREAD_ID` (separate from the implementation review THREAD_ID).

**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the test code and project test conventions, whether the reviewer had full context on the testing strategy and requirements and whether it improves test quality or is a preference / false positive. Contest doubtful findings via `codex-call.sh --resume <THREAD_ID>` with specific reasoning; a finding is dropped only when the reviewer explicitly concedes it in a written reply (the active reviewer is the Codex thread or, when a fallback reviewer is active, any reviewer authorized for the repo, tier S included; it must record its evidence and its concession or verification in writing, and no Codex thread is required); a reviewer that maintains it, or a reply with no clear concession, leaves it accepted and it gets fixed, and your own disagreement never drops a finding. Only findings that survive this gate are "accepted" below.

**Validate the response**: never accept a verdict on a substring match. The first non-blank line must be exactly `VERDICT: APPROVED`, `VERDICT: WARNING` or `VERDICT: BLOCKED`. A second `VERDICT:` line is no verdict, and "NOT APPROVED", "APPROVED once you fix ..." or any other qualified verdict word inside other text is no verdict. The severity lines (`CRITICAL:`, `HIGH:`, `MEDIUM:`, `LOW:`) are optional: a severity header with empty text takes the next non-blank line that is not a severity header as its text, a header with no such line (end of the output, or another severity header next) makes the whole output no verdict and never a clean round, and the placeholder text `none` or `n/a` (any case, optional trailing period) is ignored, not a finding. Any real finding at any severity means findings, whatever the verdict word: `VERDICT: APPROVED` beside a real CRITICAL or HIGH finding is findings, never a clean round, so evaluate, fix and re-review it, and never drop it. `VERDICT: APPROVED` with no real finding (the bare line, or the line plus only placeholder severity lines) is clean. Empty output, or anything else that does not parse, is no verdict: treat the call as a failed review and re-ask the same reviewer (the same Codex thread through the wrapper, or the active fallback reviewer) for one unambiguous verdict.

**Parse response**: every verdict is handled the same way: the severity of a finding decides how urgent it is, never whether it gets fixed.
- **Any accepted finding at any severity** (BLOCKED, WARNING or APPROVED with MEDIUM/LOW findings listed) → Claude fixes every accepted finding in the test files, re-verifies RED, then re-audits via `codex-call.sh --resume <THREAD_ID>` (before it, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`)).
- **Done** → a round that lists no findings, or whose every finding was dropped through the evaluation gate. Only then proceed to Phase 4.
- **Failed audit** (error, timeout or no verdict) → never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Fallback input paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report "test audit incomplete, the tests are UNREVIEWED: <blocker>" only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers; a Codex usage limit is never a blocker while tier S can run), and name the blocker when you do. Phase 4 starts only after a clean audit, or after that named blocker with the tests labeled UNREVIEWED in the delivery report and in your final message. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict.

**Fallback input (tier S)**: the fallback reviewer sees only the one file you hand it, so every tier S call uses ONE context file, built exactly as below and never a bare diff. It carries what the Codex call carried: the sanitized task requirements (the task or plan text, every task of a multi-task run, with any secret, credential or `.env` value removed), the review or audit instructions you sent to Codex (for a test audit, its Evaluate list), every carried finding (raised in an earlier round and still open) and every contested finding with your reasoning, then the sanitized diff, made after the same intent-to-add step for the files this task created as the Codex call. Rebuild the file for every round so it holds the CURRENT diff and the current findings.

```
CTX="$(mktemp)"
cat > "$CTX" <<'EOF'
TASK REQUIREMENTS:
<the sanitized task requirements>

REVIEW INSTRUCTIONS:
<the review or audit instructions sent to Codex>

OPEN FINDINGS:
<every carried and contested finding with your reasoning, or the word none>

DIFF:
EOF
git diff $START_SHA -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' >> "$CTX"
~/.claude/config/scripts/reviewer.sh S "$CTX" <out-file>
```


There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Fallback input paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers; a Codex usage limit is never a blocker while tier S can run), and name the blocker when you do. A reviewer that asks for the same kind of thing every round (for example the tracking marker a repo rule such as REVIEW.md requires) is not looping or unsatisfiable: satisfy what it cites and re-review. Never conclude the reviewer is stuck, never report that no clean round was reached and never hand the user a keep-going-or-drop-it decision; a doubt about a finding goes through the discussion path, and the only other exit is the failed-review rule. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict. Every re-review or re-audit round goes to the reviewer that is active: while a fallback reviewer is active (see the usage-limit paragraph), send the revised plan or diff to that same fallback reviewer, never `--resume` a Codex thread that cannot answer and return to `--resume` only once Codex answers again.

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

**Step R1: Run Codex Review via codex-call.sh**

Before calling Codex, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`); the diff against $START_SHA then shows all created files, not just modifications.

Call `codex-call.sh` with:
- append to prompt: `"Be concise. Return only the structured verdict format. No prose."`
- `prompt`:

```
Run `git diff $START_SHA -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'` to see all changes made during this session, then review them.

Return ONLY a structured verdict in this exact format — no explanations, no prose:

VERDICT: APPROVED | WARNING | BLOCKED

CRITICAL: <findings>
HIGH: <findings>
MEDIUM: <findings>
LOW: <findings>

Omit any severity line with no findings (never write placeholder lines such as "HIGH: none", and never a severity header with no text after it). A clean review is exactly the one line `VERDICT: APPROVED`.
```

Save the returned `THREAD_ID` for follow-up replies.

**Failed review**: a Codex call that errors, times out, exits without a final message (`codex-call.sh` exits non-zero with "UNREVIEWED") or replies with output that is no verdict under the Validate the response grammar below (empty output, no valid first `VERDICT:` line, a second `VERDICT:` line), is NOT an approval and never "no findings". Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Fallback input paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and tell the user: "Codex review incomplete. The changes are UNREVIEWED: <blocker>." only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers; a Codex usage limit is never a blocker while tier S can run), and name the blocker when you do. Never deliver the changes as reviewed. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict.

**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the actual code, whether the reviewer had full context for intentional decisions and whether it improves correctness/security or is a preference/false positive. Contest doubtful findings via `codex-call.sh --resume <THREAD_ID>` with specific reasoning; a finding is dropped only when the reviewer explicitly concedes it in a written reply (the active reviewer is the Codex thread or, when a fallback reviewer is active, any reviewer authorized for the repo, tier S included; it must record its evidence and its concession or verification in writing, and no Codex thread is required); a reviewer that maintains it, or a reply with no clear concession, leaves it accepted and it gets fixed, and your own disagreement never drops a finding. Only findings that survive this gate are "accepted" below.

**Validate the response**: never accept a verdict on a substring match. The first non-blank line must be exactly `VERDICT: APPROVED`, `VERDICT: WARNING` or `VERDICT: BLOCKED`. A second `VERDICT:` line is no verdict, and "NOT APPROVED", "APPROVED once you fix ..." or any other qualified verdict word inside other text is no verdict. The severity lines (`CRITICAL:`, `HIGH:`, `MEDIUM:`, `LOW:`) are optional: a severity header with empty text takes the next non-blank line that is not a severity header as its text, a header with no such line (end of the output, or another severity header next) makes the whole output no verdict and never a clean round, and the placeholder text `none` or `n/a` (any case, optional trailing period) is ignored, not a finding. Any real finding at any severity means findings, whatever the verdict word: `VERDICT: APPROVED` beside a real CRITICAL or HIGH finding is findings, never a clean round, so evaluate, fix and re-review it, and never drop it. `VERDICT: APPROVED` with no real finding (the bare line, or the line plus only placeholder severity lines) is clean. Empty output, or anything else that does not parse, is no verdict: treat the call as a failed review and re-ask the same reviewer (the same Codex thread through the wrapper, or the active fallback reviewer) for one unambiguous verdict.

Classify the verdict. Every verdict is handled the same way: the severity of a finding decides how urgent it is, never whether it gets fixed.
- **Any accepted finding at any severity** (BLOCKED, WARNING or APPROVED with MEDIUM/LOW findings listed) → fix and re-review (R2).
- **Done** → a round that lists no findings (`VERDICT: APPROVED`, bare or with only placeholder severity lines), or whose every finding was dropped through the evaluation gate. Only then go to Phase 7.

**Step R2: Fix and Re-review (every round with accepted findings)**

Address ALL accepted findings before re-reviewing:
- Collect every accepted CRITICAL, HIGH, MEDIUM and LOW finding from the last review
- Fix them all with Edit/Write in one batch
- Run the test suite (must stay GREEN) and lint to verify
- Before re-calling, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`); then re-call Codex via `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) with:

```
Run `git diff $START_SHA -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'` again to see the updated changes, then re-review.

Return ONLY the structured verdict in the same format.
```

One review per round, not one review per fix.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Fallback input paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers; a Codex usage limit is never a blocker while tier S can run), and name the blocker when you do. A reviewer that asks for the same kind of thing every round (for example the tracking marker a repo rule such as REVIEW.md requires) is not looping or unsatisfiable: satisfy what it cites and re-review. Never conclude the reviewer is stuck, never report that no clean round was reached and never hand the user a keep-going-or-drop-it decision; a doubt about a finding goes through the discussion path, and the only other exit is the failed-review rule. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict. Every re-review or re-audit round goes to the reviewer that is active: while a fallback reviewer is active (see the usage-limit paragraph), send the revised plan or diff to that same fallback reviewer, never `--resume` a Codex thread that cannot answer and return to `--resume` only once Codex answers again.

### Phase 7: Delivery

End the final report with exactly one machine-readable line, `AUDIT-STATUS: APPROVED reviewer=<name>` when the last review of the final state was clean, or `AUDIT-STATUS: UNREVIEWED reviewer=<name or none>` when it was not; no other line may start with `AUDIT-STATUS:`, and this line is the last non-blank line of the report.

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
