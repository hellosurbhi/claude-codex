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
- `Bash` running `~/.claude/config/scripts/codex-call.sh` (wraps `codex exec`; follow-ups use `--resume THREAD_ID`): Codex test audit and Route B implementation
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

Before the audit, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`).

**Call `codex-call.sh`** (iteration 1; first run step 1 of the Review record below, which builds `.claude/review/review-input.diff` from the intent-to-add diff of the new test files, and dispatch only after it prints "review input ready"):
- append to prompt: `"Be concise. Return only the structured verdict format. No prose."`
- `prompt`: the REVIEW INSTRUCTIONS section of the Review context file; send the whole file with `--prompt-file` (add `--resume <THREAD_ID>` for a follow-up), never as an argument:

```
The diff to review is in the DIFF section at the end of this prompt (the contents of `.claude/review/review-input.diff`, built by step 1 of the Review record: the newly created test files, credential values masked). Review the tests ONLY (no implementation exists yet). Do not run `git diff` yourself. The task requirements are in the TASK REQUIREMENTS section of this prompt: judge whether the change satisfies them as well as whether it is correct.

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

**Failed audit**: a Codex call that errors, times out, exits without a final message (`codex-call.sh` exits non-zero with "UNREVIEWED") or replies with output that is no verdict under the Validate the response grammar below (empty output, no valid first `VERDICT:` line, a second `VERDICT:` line), is NOT an approval and never "no findings". Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Review context paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report "test audit incomplete, the tests are UNREVIEWED: <blocker>" only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers; a Codex usage limit is never a blocker while tier S can run), and name the blocker when you do. Phase 4 starts only after a clean audit, or after that named blocker with the tests labeled UNREVIEWED in the delivery report and in your final message. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict.

**Review context (every reviewer call)**: every reviewer, the Codex call and the tier S fallback alike, is handed ONE file, `.claude/review/review-context.txt` at the repository top, built exactly as below and never a bare diff. The Codex call (`codex-call.sh`) sends it as the prompt with `--prompt-file` (a new call and every `--resume` call alike; never the prompt as a command argument, because a large diff exceeds the operating system's argument limit and Codex would never start), and `reviewer.sh S` takes the same file as its context, so the primary and the fallback reviewer judge the same requirements and the same bytes. It holds, in order: the task requirements you write into it (the task or plan text, every task of a multi-task run, so the reviewer can judge whether the change satisfies what was asked and not only whether it is correct), the review or audit instructions (for a test audit, its Evaluate list), every carried finding (raised in an earlier round and still open) and every contested finding with your reasoning, then the review input `.claude/review/review-input.diff` that step 1 of the review record built (after the same intent-to-add step for the files this task created), never a second `git diff` and never the raw snapshot: run step 1 again before each round so it holds the current diff. The text you write (requirements, instructions, findings) goes through the same `~/.claude/config/scripts/redact-diff.sh` as the diff (in its `--text` mode, which treats the input as plain text, so a private key block in the requirements is masked too), so the same best-effort mask of inline credential values applies to it, with the same limits: it masks private key blocks, cloud and API tokens, Bearer tokens, JWTs and password and secret assignments on any line, it is not a guarantee, and a secret in a shape it does not know passes through, so still write the requirements without any secret, credential or `.env` value. The text part is never typed into a shell command (r22 finding 1: a pasted line such as `EOF`, a command substitution or a backtick would otherwise end the heredoc early or run as shell): write it with your file-writing tool (Write, never a heredoc, echo or printf carrying the pasted text) to `.claude/review/requirements.raw.txt` at the repository top, as three sections in this order, each starting with its title on its own line: `TASK REQUIREMENTS:` (the task requirements, written without any secret, credential or `.env` value), `REVIEW INSTRUCTIONS:` (the review or audit instructions: the prompt text of this round, with its appended line) and `OPEN FINDINGS:` (every carried and contested finding with your reasoning, or the word none). The shell block below contains none of that text: it masks the raw file with `--text`, adds the `DIFF:` title and appends the review input, then deletes the raw file, so a stale one is never reused. A missing or empty raw file means no context is sent and no reviewer is called. Rebuild the file for every round so it holds the CURRENT diff and the current findings, and dispatch only after it prints "review context ready". If the review input is missing or empty, or the redaction fails, the context file is deleted and no context is sent, so no reviewer is called, there is no verdict and the work stays unreviewed.

```
R="$(git rev-parse --show-toplevel)" || R=""
CTX="$R/.claude/review/review-context.txt"
[ -n "$R" ] && rm -f "$CTX"
RAW="$R/.claude/review/requirements.raw.txt"
if [ -n "$R" ] && [ -s "$R/.claude/review/review-input.diff" ] && [ -s "$RAW" ] && ~/.claude/config/scripts/redact-diff.sh --text < "$RAW" > "$CTX" && printf '\nDIFF:\n' >> "$CTX"
then cat "$R/.claude/review/review-input.diff" >> "$CTX" && rm -f "$RAW" && echo "review context ready: $CTX" || { rm -f "$CTX"; echo "the review context could not be built: no context is sent"; }
else [ -n "$R" ] && rm -f "$CTX"; echo "the review input .claude/review/review-input.diff or the requirements file .claude/review/requirements.raw.txt is missing or empty, or the redaction failed: no context is sent"; fi
```


**Validate the response**: never accept a verdict on a substring match. Any non-zero exit of `codex-call.sh`, including one that stops on its own arguments before Codex is called (a bad argument, a missing role file, a missing or empty prompt file), is a failed attempt: the last attempt decides, so such an exit voids every earlier approval of this state until a later call returns a clean verdict. The first non-blank line must be exactly `VERDICT: APPROVED`, `VERDICT: WARNING` or `VERDICT: BLOCKED`. A second `VERDICT:` line is no verdict, and "NOT APPROVED", "APPROVED once you fix ..." or any other qualified verdict word inside other text is no verdict. The severity lines (`CRITICAL:`, `HIGH:`, `MEDIUM:`, `LOW:`) are optional: a severity header with empty text takes the next non-blank line that is not a severity header as its text, a header with no such line (end of the output, or another severity header next) makes the whole output no verdict and never a clean round, and the placeholder text `none` or `n/a` (any case, optional trailing period) is ignored, not a finding. Any real finding at any severity means findings, whatever the verdict word: `VERDICT: APPROVED` beside a real CRITICAL or HIGH finding is findings, never a clean round, so evaluate, fix and re-review it, and never drop it. `VERDICT: APPROVED` with no real finding (the bare line, or the line plus only placeholder severity lines) is clean. Empty output, or anything else that does not parse, is no verdict: treat the call as a failed review and re-ask the same reviewer (the same Codex thread through the wrapper, or the active fallback reviewer) for one unambiguous verdict.

**Parse response**: every verdict is handled the same way: the severity of a finding decides how urgent it is, never whether it gets fixed.
- **Any findings at any severity** (BLOCKED, WARNING or APPROVED with MEDIUM/LOW findings listed) → critically evaluate each one (see below), fix the accepted ones in the test files, re-verify RED and re-audit.
- **Done** → a round whose reply is exactly `VERDICT: APPROVED` (the bare line, or that line plus only placeholder severity lines) with zero findings at any severity, or whose every finding was dropped through the discussion path. A `VERDICT: BLOCKED` or `VERDICT: WARNING` reply that lists no finding is not clean and not actionable: send ONE follow-up to the same reviewer (the same Codex thread through `--resume`, or the active fallback reviewer) asking it to list its findings, and treat a repeat that still lists none as no verdict (a failed call: the fallback chain applies). Only then go to Phase 4.

**Critical Evaluation of Test Audit Findings**

Before fixing any issues, critically evaluate each finding, at every severity:

1. **Assess correctness**: Is the finding technically accurate? Check the test code and project test conventions.
2. **Check context**: Does the reviewer have full context about the testing strategy and requirements?
3. **Verify applicability**: Does the suggestion improve test quality, or is it a preference / false positive?

**If a finding seems incorrect or questionable:**
- Do NOT fix it yet. Instead, reply to the reviewer with your technical reasoning.
- Call `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) explaining why the finding appears incorrect, with specific test code references.
- If the reviewer provides additional justification that is convincing, accept the finding.
- Drop the finding only when the reviewer explicitly concedes it in writing (the active reviewer is the Codex thread or, when a fallback reviewer is active, any reviewer authorized for the repo, tier S included; it must record its evidence and its concession or verification in writing, and no Codex thread is required). If it maintains the finding or gives no clear answer, accept it and fix it; your own disagreement never drops a finding.
- A discussion reply never ends the loop by itself: the loop ends only when a round has no accepted findings.

**If findings are accepted:** Claude fixes every accepted finding (CRITICAL, HIGH, MEDIUM or LOW) in the test files, re-verifies RED and re-calls `codex-call.sh --resume <THREAD_ID>` to re-audit (before it, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`)).

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Review context paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers; a Codex usage limit is never a blocker while tier S can run), and name the blocker when you do. A reviewer that asks for the same kind of thing every round (for example the tracking marker a repo rule such as REVIEW.md requires) is not looping or unsatisfiable: satisfy what it cites and re-review. Never conclude the reviewer is stuck, never report that no clean round was reached and never hand the user a keep-going-or-drop-it decision; a doubt about a finding goes through the discussion path, and the only other exit is the failed-review rule. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict. Every re-review or re-audit round goes to the reviewer that is active: while a fallback reviewer is active (see the usage-limit paragraph), send the revised plan or diff to that same fallback reviewer, never `--resume` a Codex thread that cannot answer and return to `--resume` only once Codex answers again.

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

**Review record (every reviewer round)**: the code-reviewer agent is Claude, so its verdict never reaches the Codex wrapper log, and the final report's `AUDIT-STATUS` line names no state. Each reviewer round of this workflow (every Route A and Route B round and, in the usage-limit chain, the fallback reviewer's out-file) therefore has two steps that bind the saved reply to the exact diff the reviewer judged. Step 1 runs BEFORE the reviewer is dispatched, after the same intent-to-add step that builds the reviewer's diff. Run it unchanged:

```
if R="$(git rev-parse --show-toplevel)" && [ -n "$R" ]; then (cd "$R" || exit 1
mkdir -p .claude/review; rm -f .claude/review/final-review.txt .claude/review/reviewed.diff .claude/review/review-input.diff
if H="$(set -o pipefail; git diff "${START_SHA:?}" -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' ':(top,exclude).claude/review' | tee .claude/review/reviewed.diff | shasum -a 256 | cut -d' ' -f1)" && [ -s .claude/review/reviewed.diff ] && (set -o pipefail; ~/.claude/config/scripts/redact-diff.sh < .claude/review/reviewed.diff > .claude/review/review-input.diff) && [ -s .claude/review/review-input.diff ]; then echo "review input ready: send .claude/review/review-input.diff to every reviewer"
else rm -f .claude/review/reviewed.diff .claude/review/review-input.diff; echo "no review input (the diff or its redaction failed, or the diff is empty): do NOT dispatch any reviewer, fix the cause and run step 1 again"; fi
); else echo "no repo root (git rev-parse --show-toplevel failed): do NOT dispatch the reviewer, run step 1 again from inside the repository"; fi
```
Dispatch only after it prints "review input ready". Send every reviewer `.claude/review/review-input.diff` (the primary reviewer and the tier S fallback alike), never a fresh `git diff` and never `.claude/review/reviewed.diff`: the review input is made from exactly the bytes hashed into `H`, with credential values masked. Step 2 runs when the reply arrives, before any fix. Before it, write the reviewer's reply verbatim, byte for byte, with your file-writing tool (Write, never a heredoc, echo or printf carrying the pasted reply) to `.claude/review/reply.raw.txt` at the repository top; the reply is never typed into a shell command. Then run it unchanged:

```
if R="$(git rev-parse --show-toplevel)" && [ -n "$R" ]; then (cd "$R" || exit 1
H="$(shasum -a 256 < .claude/review/reviewed.diff | cut -d' ' -f1)"
if N="$(set -o pipefail; git diff "${START_SHA:?}" -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' ':(top,exclude).claude/review' | shasum -a 256 | cut -d' ' -f1)" && [ -s .claude/review/reviewed.diff ] && [ "$N" = "$H" ] && [ -s .claude/review/reply.raw.txt ]; then
{ printf 'REVIEWED-DIFF: %s\nREVIEWED-AS: redacted-snapshot\n' "$H"; cat .claude/review/reply.raw.txt; } > .claude/review/final-review.txt && rm -f .claude/review/reply.raw.txt
else rm -f .claude/review/final-review.txt; echo "the diff failed, is empty or the tree changed while the reviewer ran: this round is void, there is no verdict for the current tree, review again"; fi
); else echo "no repo root (git rev-parse --show-toplevel failed): this round is void, there is no verdict for the current tree, run step 2 again from inside the repository"; fi
```
The reply travels only as the file `.claude/review/reply.raw.txt` (r22 finding 1: a reply line such as `REVIEW_RECORD_END`, `EOF` or a command substitution can no longer end a heredoc early or run as shell, because no shell text carries it); a missing or empty reply file voids the round like a changed tree, and the file is deleted once recorded. Both steps first resolve the repository root with `git rev-parse --show-toplevel` and run from there, so the record and the snapshot land at the root whichever folder the shell is in; a failed lookup records nothing and voids the round. A failed `git diff`, an empty snapshot or a changed tree voids the round: nothing is recorded, any old record is removed, the earlier diff's approval never carries over, and the next round starts again at step 1. Each round overwrites the file, so it always holds the latest round. The record carries the pre-dispatch hash (taken from the snapshot, never from the tree after the reply), and the whole `.claude/review/` directory is excluded from the hashed diff (the record, the snapshot and anything added there later): a tracked or intent-to-add file in it is rewritten around the hash, so a diff that included it would make every record stale. A record counts as approval only when its reply is exactly `VERDICT: APPROVED` with zero findings and its hash is that of the final diff: any edit after a round makes the record stale, which needs a new review round and a new record, and a final report whose record is missing, stale or not clean must end `AUDIT-STATUS: UNREVIEWED`. The record's second line is always `REVIEWED-AS: redacted-snapshot`: every reviewer, the code-reviewer agent and the tier S fallback alike, is handed `.claude/review/review-input.diff` (the snapshot after `redact-diff.sh`) and never the raw snapshot. `REVIEWED-DIFF` is the hash of the raw snapshot the review input is made from. The record claims nothing more: Codex runs locally with read access to the working tree, so redaction governs what we put in the prompt, not what a local tool could open, and a reviewer that ran its own commands in the repository is bound only to the tree state that hash describes, never to the bytes it read.

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
6. Before the review, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`) (so the diff against $START_SHA includes new files)
7. If Codex hit its usage limit in this run (see the usage-limit paragraph under the Codex availability check), this step and the dispute handling after it are REPLACED by that paragraph's fallback chain: the code-reviewer agent is Claude reviewing its own code and never counts as the review then. Otherwise launch Task agent (subagent_type: "feature-dev:code-reviewer") with:
   - the contents of `.claude/review/review-input.diff`, the redacted snapshot step 1 of the review record builds from `git diff $START_SHA -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'` (never a fresh `git diff` and never the raw snapshot)
   - Original task requirements
   - Required output: exactly one `VERDICT: APPROVED | WARNING | BLOCKED` line first, then optional `CRITICAL:`, `HIGH:`, `MEDIUM:` and `LOW:` lines listing every finding at that severity (omit a severity with no findings; a clean review is exactly `VERDICT: APPROVED`). A reply that is no verdict under the Validate the response grammar is a failed review: re-launch it.
8. **Critical Evaluation**: Before fixing, critically evaluate each finding, at every severity:
   - **Assess correctness**: Is it technically accurate? Check actual code and project conventions.
   - **Check context**: Does the reviewer have full context, or is it flagging intentional design?
   - **Verify applicability**: Does it improve correctness/security, or is it a style preference / false positive?
   - **If a finding seems incorrect**: Do NOT fix it yet. Launch a new code-reviewer agent with the original diff, the contested findings and your technical reasoning. Ask it to re-evaluate only the contested items. Keep every finding accepted unless that agent explicitly withdraws it in writing; your own disagreement never drops a finding.
9. Any accepted finding at any severity (CRITICAL, HIGH, MEDIUM or LOW) → fix every accepted finding in one batch with Edit/Write, re-run the full test suite (must stay GREEN), then run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`), then re-run the code-reviewer from step 7 on the new `git diff $START_SHA -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`.
10. Repeat steps 7 to 9 until a round has no accepted findings. There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Review context paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers; a Codex usage limit is never a blocker while tier S can run), and name the blocker when you do. A reviewer that asks for the same kind of thing every round (for example the tracking marker a repo rule such as REVIEW.md requires) is not looping or unsatisfiable: satisfy what it cites and re-review. Never conclude the reviewer is stuck, never report that no clean round was reached and never hand the user a keep-going-or-drop-it decision; a doubt about a finding goes through the discussion path, and the only other exit is the failed-review rule. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict.
11. Go to Phase 5

---

### Route B: Large Change, Codex Implements (GREEN; review until a round has no accepted findings, no iteration cap)

**MANDATORY**: When Route B is selected, you MUST NOT use Edit/Write tools for implementation. All implementation MUST go through `codex-call.sh`. Claude's role in Route B is context retrieval, test ownership, verification and review, not implementation. The ONLY exception is fixing minor regressions found during self-verification (Step B2) that are clearly caused by Codex output (e.g. a missing import, a typo in a generated file).

**No post-routing rationalization**: Once Route B is selected, the routing decision applies to ALL tasks in the plan. Do NOT re-evaluate individual tasks for complexity. If you find yourself thinking "this task is simple enough to do directly" or "this is just a deletion" — STOP. That is the routing decision being second-guessed. The routing already accounted for overall complexity. Every task goes through Codex.

**Codex availability check**: run `test -x ~/.claude/config/scripts/codex-call.sh && codex --version`. If either fails, fall back to Route A and announce: "Codex unavailable: falling back to Claude direct implementation." This fallback is ONLY for when Codex is technically unavailable (the wrapper or the CLI is missing). The same fallback applies when a Codex call fails with a usage-limit or quota error (the error text names a usage limit or a reset time): a retry cannot succeed before the reset, so do not stop and do not wait. Announce "Codex over its usage limit: falling back to Claude direct implementation (Route A)" and implement the plan directly with Edit/Write. The review leg must never be Claude reviewing its own code: do not use the `code-reviewer` Claude agent for the Step B4 review in this case. Review through the authorized fallback chain instead, in this order, validating every answer against the VERDICT grammar: (1) a fresh Codex thread when quota returns; (2) `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (a separate Sonnet reviewer on the full diff including the implementation, built by the Review context paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff). Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. Findings at any severity are fixed and re-reviewed (no cap, retry and switch when a call dies), and the change stays pending, never reported as done or unreviewed, until one of those reviewers returns a clean verdict on the current head, or a named non-transient blocker ends the chain: a missing fallback script such as `reviewer.sh`, missing credentials or a reviewer outage whose error text names its cause. Then stop, report the work as UNREVIEWED with that blocker named in the final message and never retry it. Transient failures (a call that died, timed out or returned nothing) are not blockers and retry with no cap. A reply counts as clean only when it is exactly the `VERDICT: APPROVED` line alone (the form reviewer.sh returns, which omits empty severity lines) or that line plus the four `none` lines (the Codex form), with no other text; when a reviewer adds prose or a finding note to an APPROVED reply, treat it as not clean and run a fresh review of the current head. It MUST NOT be used because a task seems "too simple for Codex" or because Claude judges direct editing would be faster. (`codex mcp-server` was removed in Codex CLI 0.154.0, so there are no `mcp__codex__*` tools; every call goes through `codex-call.sh`, which wraps `codex exec`.) A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict.

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

**Note on agent spawning**: Codex runs in a sandboxed shell and cannot spawn Claude agents directly. For direct task descriptions with 3+ tasks, Claude spawns a subagent per task, each subagent owns its Codex thread (its own `THREAD_ID`) for that task, keeping both the main context and each Codex session scoped and clean.

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

4. If tests fail: call codex-call.sh --resume <THREAD_ID> --sandbox workspace-write with the THREAD_ID and failure output. The failure output is pasted free text: write the prompt to `.claude/review/prompt.raw.txt` with your file-writing tool and pass `--prompt-file`, never inside a quoted argument. Repeat until the task's tests pass.

5. Report back: files changed, final test result, any unresolved failures.
```

3. After each subagent: run `git diff $TASK_SHA` (scoped to this task only) to verify what changed, run the task's tests to confirm GREEN

**Important**: Each subagent owns its own Codex `THREAD_ID`. There is no shared THREAD_ID across tasks. Step B4 (code review) therefore uses the `code-reviewer` Task agent, not `codex-call.sh --resume <THREAD_ID>`, since there is no single session to reply to.

---

**Path 3 (direct task description, <3 tasks)** — Direct Codex call

Call `codex-call.sh` (first call) or `codex-call.sh --resume <THREAD_ID>` (every fix round after that):
- prompt: `"Implement the following task. Tests have already been written — your implementation must make all tests pass.\n\nTask: {task}\n\nTest files:\n{test file contents}\n\nContext:\n{sanitized key file contents}"` Because this prompt carries pasted free text, write the whole prompt with your file-writing tool (Write, never a heredoc, echo or printf) to `.claude/review/prompt.raw.txt` and pass it with `--prompt-file`, never inside a quoted argument (r22 finding 1: `$(...)`, backticks or a quote in the text would run as shell).
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

Before the review, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`) (so the diff against $START_SHA includes new files).

Launch Task agent (subagent_type: "feature-dev:code-reviewer") with:
- the contents of `.claude/review/review-input.diff`, the redacted snapshot step 1 of the review record builds from `git diff $START_SHA -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'` (never a fresh `git diff` and never the raw snapshot)
- Original task requirements
- Required output: exactly one `VERDICT: APPROVED | WARNING | BLOCKED` line first, then optional `CRITICAL:`, `HIGH:`, `MEDIUM:` and `LOW:` lines listing every finding at that severity (omit a severity with no findings; a clean review is exactly `VERDICT: APPROVED`). A reply that is no verdict under the Validate the response grammar is a failed review: re-launch it.

**Validate the response**: never accept a verdict on a substring match. Any non-zero exit of `codex-call.sh`, including one that stops on its own arguments before Codex is called (a bad argument, a missing role file, a missing or empty prompt file), is a failed attempt: the last attempt decides, so such an exit voids every earlier approval of this state until a later call returns a clean verdict. The first non-blank line must be exactly `VERDICT: APPROVED`, `VERDICT: WARNING` or `VERDICT: BLOCKED`. A second `VERDICT:` line is no verdict, and "NOT APPROVED", "APPROVED once you fix ..." or any other qualified verdict word inside other text is no verdict. The severity lines (`CRITICAL:`, `HIGH:`, `MEDIUM:`, `LOW:`) are optional: a severity header with empty text takes the next non-blank line that is not a severity header as its text, a header with no such line (end of the output, or another severity header next) makes the whole output no verdict and never a clean round, and the placeholder text `none` or `n/a` (any case, optional trailing period) is ignored, not a finding. Any real finding at any severity means findings, whatever the verdict word: `VERDICT: APPROVED` beside a real CRITICAL or HIGH finding is findings, never a clean round, so evaluate, fix and re-review it, and never drop it. `VERDICT: APPROVED` with no real finding (the bare line, or the line plus only placeholder severity lines) is clean. Empty output, or anything else that does not parse, is no verdict: treat the call as a failed review and re-ask the same reviewer (the same Codex thread through the wrapper, or the active fallback reviewer) for one unambiguous verdict.

Parse reviewer response:
- Exactly `VERDICT: APPROVED` (the bare line, or that line plus only placeholder severity lines) with zero findings at any severity → approved, go to Phase 5. A `VERDICT: BLOCKED` or `VERDICT: WARNING` reply that lists no finding is not clean and not actionable: send ONE follow-up to the same reviewer (the same Codex thread through `--resume`, or the active fallback reviewer) asking it to list its findings, and treat a repeat that still lists none as no verdict (a failed call: the fallback chain applies).
- Any finding at any severity → evaluate as below, fix and re-review.

**Critical Evaluation** (before fixing): Critically evaluate each finding, at every severity:
- **Assess correctness**: Is it technically accurate? Check actual code and project conventions.
- **Check context**: Does the reviewer have full context, or is it flagging intentional design?
- **Verify applicability**: Does it improve correctness/security, or is it a style preference / false positive?
- **If a finding seems incorrect**: Do NOT fix it yet. Launch a new code-reviewer agent with the original diff, the contested findings and your technical reasoning. Ask it to re-evaluate only the contested items. Keep every finding accepted unless that agent explicitly withdraws it in writing; your own disagreement never drops a finding.

After evaluation, every round with accepted findings (CRITICAL, HIGH, MEDIUM or LOW) applies the fixes and re-reviews:
- **Route each accepted finding by what it changes** (Step B3: Claude owns every post-RED test edit and Codex never modifies test files, so a review fix is never sent to Codex when it touches a test). A test finding (a test file to add, correct or remove, or a coverage gap) is fixed by Claude with Edit/Write, then re-verified RED where the test is new or corrected and GREEN against the implementation, exactly as Step B3 says. An implementation finding goes to Codex, by the paths below. A finding that touches both is split: Claude applies the test part first, then Codex gets only the implementation part, told that the test part is already done and that it must not modify test files. A round whose accepted findings are all test findings makes no Codex call; the re-review follows after Claude's fixes.
- (implementation findings only) 3+ task path → dispatch a Claude subagent per affected task with the accepted reviewer feedback verbatim; the subagent applies the fix by calling `codex-call.sh` itself, resuming that task's own Codex thread (the `THREAD_ID` it reported for that task) or starting a new one for that task if none was kept, and never edits the code directly; there is no shared `THREAD_ID` across tasks, so never resume another task's thread.
- (implementation findings only) Single Codex session path → call `codex-call.sh --resume <THREAD_ID> --sandbox workspace-write` with the accepted reviewer feedback verbatim.
- Route B's no-Edit/Write rule holds either way. Verify with the test suite (must stay GREEN), then run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it, so those and other unrelated untracked files do not reach the reviewer; the reviewer is read-only and cannot update the index, so new files reach the diff only this way; a modified tracked secret file such as `.env.production` is also left out of the diff with an exclude pathspec like `-- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`), then re-run `code-reviewer` on the new `git diff $START_SHA -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key'`.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Review context paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers; a Codex usage limit is never a blocker while tier S can run), and name the blocker when you do. A reviewer that asks for the same kind of thing every round (for example the tracking marker a repo rule such as REVIEW.md requires) is not looping or unsatisfiable: satisfy what it cites and re-review. Never conclude the reviewer is stuck, never report that no clean round was reached and never hand the user a keep-going-or-drop-it decision; a doubt about a finding goes through the discussion path, and the only other exit is the failed-review rule. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict. Every re-review or re-audit round goes to the reviewer that is active: while a fallback reviewer is active (see the usage-limit paragraph), send the revised plan or diff to that same fallback reviewer, never `--resume` a Codex thread that cannot answer and return to `--resume` only once Codex answers again.

---

### Phase 5: Delivery

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
- Route: Small (Claude) / Large (Codex)
- Code review: clean after N rounds / N findings fixed, N dropped through discussion
- Remaining findings: none (the loop only ends on a clean round)

### Recommended Next Steps
1. [ ] Run full test suite
2. [ ] Verify coverage meets project standards
```
