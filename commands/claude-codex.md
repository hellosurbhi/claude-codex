---
description: "Claude implements, Codex reviews uncommitted changes"
argument-hint: "<task description or path/to/plan.md>"
model: claude-sonnet-4-6
allowed-tools: ["AskUserQuestion", "Task", "Read", "Glob", "Grep", "Write", "Edit", "Bash"]
---

> **Deprecated**: This command has been converted to a skill (`/claude-codex`).
> The skill version is recommended for new usage and supports eval-based testing.
> This command is retained for backward compatibility (model pinning, tool restrictions).

# Claude-Codex — Claude Implements, Codex Reviews

$ARGUMENTS

---

## Core Protocols

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

### Phase 3: Codex Review (re-review until a round has no accepted findings at any severity; no iteration cap)

**Step R1: Run Codex Review via codex-call.sh**

Before the call, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it; the review snapshot (`review-snapshot.sh`) also carries every other untracked non-ignored file, so ignore or remove any stray file you do not want reviewed, and it leaves secret-named paths such as `.env.production` out of the diff by itself). Then build the review input (the Review input paragraph) and dispatch only after it prints "review input ready". Call Codex via `codex-call.sh` with:
- append to prompt: `"Be concise. Return only the structured verdict format. No prose."`
- `prompt`: the REVIEW INSTRUCTIONS section of the Review context file; send the whole file with `--prompt-file` (add `--resume <THREAD_ID>` for a follow-up), never as an argument:

**Private review folder (before any file is written under `.claude/review`)**: that folder holds unredacted task text, prompts, replies and diffs, so create it private first, from the repository top, with `R="$(git rev-parse --show-toplevel)" && (umask 077; mkdir -p "$R/.claude/review" && chmod 700 "$R/.claude/review")`. A mode-700 folder keeps every file in it private whatever mode your file-writing tool gives the file, and every command below writes under `umask 077`, so the files it creates are mode 600. A raw, unredacted copy is never left behind: a command that writes one deletes it before it ends.

```
The diff to review is in the DIFF section at the end of this prompt (the contents of `.claude/review/review-input.diff`, built by the Review input paragraph: all uncommitted changes, credential values masked). Review it. Do not run `git diff` yourself. The task requirements are in the TASK REQUIREMENTS section of this prompt: judge whether the change satisfies them as well as whether it is correct.

Return ONLY a structured verdict in this exact format — no explanations, no prose:

VERDICT: APPROVED | WARNING | BLOCKED

CRITICAL: <findings>
HIGH: <findings>
MEDIUM: <findings>
LOW: <findings>

Omit any severity line with no findings (never write placeholder lines such as "HIGH: none", and never a severity header with no text after it). A clean review is exactly the one line `VERDICT: APPROVED`.
```

Save the returned `THREAD_ID` for follow-up replies.

**Critical evaluation gate** (before acting on ANY finding): assess whether it is technically accurate against the actual code, whether the reviewer had full context for intentional decisions and whether it improves correctness/security or is a preference/false positive. Contest doubtful findings via `codex-call.sh --resume <THREAD_ID>` with specific reasoning; a finding is dropped only when the reviewer explicitly concedes it in a written reply (the active reviewer is the Codex thread or, when a fallback reviewer is active, any reviewer authorized for the repo, tier S included; it must record its evidence and its concession or verification in writing, and no Codex thread is required); a reviewer that maintains it, or a reply with no clear concession, leaves it accepted and it gets fixed, and your own disagreement never drops a finding. Only findings that survive this gate are "accepted" below.

**Validate the response**: never accept a verdict on a substring match. Any non-zero exit of `codex-call.sh`, including one that stops on its own arguments before Codex is called (a bad argument, a missing role file, a missing or empty prompt file), is a failed attempt: the last attempt decides, so such an exit voids every earlier approval of this state until a later call returns a clean verdict. The first non-blank line must be exactly `VERDICT: APPROVED`, `VERDICT: WARNING` or `VERDICT: BLOCKED`. A second `VERDICT:` line is no verdict, and "NOT APPROVED", "APPROVED once you fix ..." or any other qualified verdict word inside other text is no verdict. The severity lines (`CRITICAL:`, `HIGH:`, `MEDIUM:`, `LOW:`) are optional: a severity header with empty text takes the next non-blank line that is not a severity header as its text, a header with no such line (end of the output, or another severity header next) makes the whole output no verdict and never a clean round, and the placeholder text `none` or `n/a` (any case, optional trailing period) is ignored, not a finding. Any real finding at any severity means findings, whatever the verdict word: `VERDICT: APPROVED` beside a real CRITICAL or HIGH finding is findings, never a clean round, so evaluate, fix and re-review it, and never drop it. `VERDICT: APPROVED` with no real finding (the bare line, or the line plus only placeholder severity lines) is clean. Empty output, or anything else that does not parse, is no verdict: treat the call as a failed review and re-ask the same reviewer (the same Codex thread through the wrapper, or the active fallback reviewer) for one unambiguous verdict.

Classify the verdict. Every verdict is handled the same way: the severity of a finding decides how urgent it is, never whether it gets fixed.
- **Any accepted finding at any severity** (BLOCKED, WARNING or APPROVED with MEDIUM/LOW findings listed) → fix and re-review (R2).
- **Done** → a round whose reply is exactly `VERDICT: APPROVED` (the bare line, or that line plus only placeholder severity lines) with zero findings at any severity, or whose every finding was dropped through the discussion path. A `VERDICT: BLOCKED` or `VERDICT: WARNING` reply that lists no finding is not clean and not actionable: send ONE follow-up to the same reviewer (the same Codex thread through `--resume`, or the active fallback reviewer) asking it to list its findings, and treat a repeat that still lists none as no verdict (a failed call: the fallback chain applies). Only then go to Phase 4.

**Step R2: Fix and Re-review (every round with accepted findings)**

Address ALL accepted findings before re-reviewing:
- Collect every accepted CRITICAL, HIGH, MEDIUM and LOW finding from the last review
- Fix them all with Edit/Write in one batch
- Run available tests/lint to verify
- Before re-calling, run `git add -N <each file this task created>` in your own shell first (never `.`, and never a credential, key, `.env` or other secret file even when the task created it; the review snapshot (`review-snapshot.sh`) also carries every other untracked non-ignored file, so ignore or remove any stray file you do not want reviewed, and it leaves secret-named paths such as `.env.production` out of the diff by itself); then re-call Codex via `codex-call.sh --resume <THREAD_ID>` (reuse THREAD_ID) with `--prompt-file` set to the Review context file (the text below is its REVIEW INSTRUCTIONS section; never pass it as an argument):

```
The diff to review is in the DIFF section at the end of this prompt (the contents of `.claude/review/review-input.diff`, built by the Review input paragraph: the updated changes after the fixes, rebuilt and with credential values masked). Re-review it. Do not run `git diff` yourself. The task requirements are in the TASK REQUIREMENTS section of this prompt: judge whether the change satisfies them as well as whether it is correct.

Return ONLY the structured verdict in the same format.
```

One review per round, not one review per fix.

There is no iteration cap and no stop to ask the user after N rounds: round 6, 10 or 20 continues the same way until a review round has no accepted findings at any severity (owner mandate 2026-11-12: "keep going till there are no bugs remaining. period."). A round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed exactly like a CRITICAL round. What ends the loop on preferences and false positives is the discussion path, never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Review context paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers; a Codex usage limit is never a blocker while tier S can run), and name the blocker when you do. A reviewer that asks for the same kind of thing every round (for example the tracking marker a repo rule such as REVIEW.md requires) is not looping or unsatisfiable: satisfy what it cites and re-review. Never conclude the reviewer is stuck, never report that no clean round was reached and never hand the user a keep-going-or-drop-it decision; a doubt about a finding goes through the discussion path, and the only other exit is the failed-review rule. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict. Every re-review or re-audit round goes to the reviewer that is active: while a fallback reviewer is active (see the usage-limit paragraph), send the revised plan or diff to that same fallback reviewer, never `--resume` a Codex thread that cannot answer and return to `--resume` only once Codex answers again.

**Review input (every reviewer call)**: every reviewer, the Codex call above and the tier S fallback below alike, is handed ONE input, built exactly as below after the intent-to-add step for the files this task created, and never the output of a fresh `git diff` run by the reviewer or by you. The diff goes through `~/.claude/config/scripts/redact-diff.sh`, a best-effort mask of inline credential values (private key blocks, cloud and API tokens, Bearer tokens, JWTs, password and secret assignments) on top of the path exclusions, not a guarantee, and the paths stay excluded. Only the masked output `.claude/review/review-input.diff` is ever placed in a prompt or a context file. Codex runs locally with read access to the working tree, so redaction governs what we put in the prompt, not what a local tool could open. If the script is missing or exits non-zero, or the diff is empty, the file is removed and nothing is dispatched to any reviewer, Codex or fallback: there is no verdict and the work stays unreviewed. Rebuild it before every round so it holds the CURRENT diff. Run it unchanged:

```
if R="$(git rev-parse --show-toplevel)" && [ -n "$R" ]; then (cd "$R" || exit 1
umask 077; mkdir -p .claude/review && chmod 700 .claude/review; rm -f .claude/review/review-input.diff
(set -o pipefail; ~/.claude/config/scripts/review-snapshot.sh HEAD | ~/.claude/config/scripts/redact-diff.sh > .claude/review/review-input.diff) && [ -s .claude/review/review-input.diff ] && echo "review input ready: send the contents of .claude/review/review-input.diff to every reviewer" || { rm -f .claude/review/review-input.diff; echo "no review input (the diff or its redaction failed, or the diff is empty): do NOT dispatch any reviewer, fix the cause and run this again"; }
); else echo "no repo root (git rev-parse --show-toplevel failed): do NOT dispatch any reviewer, run this again from inside the repository"; fi
```

**Review context (every reviewer call)**: every reviewer, the Codex call and the tier S fallback alike, is handed ONE file, `.claude/review/review-context.txt` at the repository top, built exactly as below and never a bare diff. The Codex call (`codex-call.sh`) sends it as the prompt with `--prompt-file` (a new call and every `--resume` call alike; never the prompt as a command argument, because a large diff exceeds the operating system's argument limit and Codex would never start), and `reviewer.sh S` takes the same file as its context, so the primary and the fallback reviewer judge the same requirements and the same bytes. It holds, in order: the task requirements you write into it (the task or plan text, every task of a multi-task run, so the reviewer can judge whether the change satisfies what was asked and not only whether it is correct), the review or audit instructions (for a test audit, its Evaluate list), every carried finding (raised in an earlier round and still open) and every contested finding with your reasoning, then the review input: the contents of `.claude/review/review-input.diff` (the Review input paragraph), the same masked bytes every reviewer receives, never a second `git diff` and never the raw diff. The text you write (requirements, instructions, findings) goes through the same `~/.claude/config/scripts/redact-diff.sh` as the diff (in its `--text` mode, which treats the input as plain text, so a private key block in the requirements is masked too), so the same best-effort mask of inline credential values applies to it, with the same limits: it masks private key blocks, cloud and API tokens, Bearer tokens, JWTs and password and secret assignments on any line, it is not a guarantee, and a secret in a shape it does not know passes through, so still write the requirements without any secret, credential or `.env` value. The text part is never typed into a shell command (r22 finding 1: a pasted line such as `EOF`, a command substitution or a backtick would otherwise end the heredoc early or run as shell): write it with your file-writing tool (Write, never a heredoc, echo or printf carrying the pasted text) to `.claude/review/requirements.raw.txt` at the repository top, as three sections in this order, each starting with its title on its own line: `TASK REQUIREMENTS:` (the task requirements, written without any secret, credential or `.env` value), `REVIEW INSTRUCTIONS:` (the review or audit instructions: the prompt text of this round, with its appended line) and `OPEN FINDINGS:` (every carried and contested finding with your reasoning, or the word none). The shell block below contains none of that text: it masks the raw file with `--text`, adds the `DIFF:` title and appends the review input, then deletes the raw file, so a stale one is never reused. A missing or empty raw file means no context is sent and no reviewer is called. Rebuild the file for every round so it holds the CURRENT diff and the current findings, and dispatch only after it prints "review context ready". If the review input is missing or empty, or the redaction fails, the context file is deleted and no context is sent, so no reviewer is called, there is no verdict and the work stays unreviewed.

```
umask 077
R="$(git rev-parse --show-toplevel)" || R=""
CTX="$R/.claude/review/review-context.txt"
[ -n "$R" ] && rm -f "$CTX"
RAW="$R/.claude/review/requirements.raw.txt"
if [ -n "$R" ] && [ -s "$R/.claude/review/review-input.diff" ] && [ -s "$RAW" ] && ~/.claude/config/scripts/redact-diff.sh --text < "$RAW" > "$CTX" && printf '\nDIFF:\n' >> "$CTX"
then cat "$R/.claude/review/review-input.diff" >> "$CTX" && rm -f "$RAW" && echo "review context ready: $CTX" || { rm -f "$CTX"; echo "the review context could not be built: no context is sent"; }
else [ -n "$R" ] && rm -f "$CTX"; echo "the review input .claude/review/review-input.diff or the requirements file .claude/review/requirements.raw.txt is missing or empty, or the redaction failed: no context is sent"; fi
```


---

### Phase 4: Delivery

End the final report with exactly one machine-readable line, `AUDIT-STATUS: APPROVED reviewer=<name>` when the last review of the final state was clean, or `AUDIT-STATUS: UNREVIEWED reviewer=<name or none>` when it was not; no other line may start with `AUDIT-STATUS:`, and this line is the last non-blank line of the report.

```markdown
## Execution Complete

### Changes
| File | Operation | Description |
|------|-----------|-------------|
| path/to/file | Modified | Description |

### Review Result
- Implemented by: Claude (active model)
- Codex review: clean after N rounds / N findings fixed, N dropped through discussion
- Remaining findings: none (the loop only ends on a clean round)

### Recommended Next Steps
1. [ ] <test step>
2. [ ] <verification step>
```
