---
name: codex-mcp
description: How to call OpenAI Codex (plan audits, code review, implementation) via codex-call.sh, the codex exec wrapper that replaced the removed Codex MCP server. Use when calling Codex for implementation, review or any cross-model collaboration.
---

# Codex Usage Guide (codex exec wrapper)

`codex mcp-server` was deprecated by OpenAI on 2026-08-24 and removed in Codex CLI 0.154.0, so the `mcp__codex__codex` and `mcp__codex__codex-reply` tools no longer exist. `codex exec` is the supported non-interactive interface. All skills call it through one wrapper.

## Tool

`~/.claude/config/scripts/codex-call.sh [--sandbox MODE] [--role FILE] [--resume THREAD_ID] [--cd DIR] (--prompt-file FILE | [--] PROMPT)`

Run it with Bash. The prompt reaches Codex on stdin either way. Use `--prompt-file` for anything large (a diff, a plan with context): a positional PROMPT is limited by the operating system's argument size, a file is not, and a missing or empty file is an error that calls nothing. Output: first line `THREAD_ID: <id>`, then Codex's final message. It exits non-zero with "UNREVIEWED" when Codex returns no message: that is never an approval. A positional PROMPT is only for fixed text you wrote yourself; any pasted free text (task text, plan text, findings, failure output, a reviewer reply) is written with your file-writing tool to a file and passed with `--prompt-file`, never placed inside a quoted shell argument or a heredoc, because `$(...)`, backticks or a terminator line in it would run as shell.

## Session Management

Sessions are stateful via the thread id. Always:
1. Save `THREAD_ID` from the first call
2. Pass `--resume THREAD_ID` for all follow-ups, with the same `--sandbox` and `--cd` as the first call (the wrapper applies them and the review profile to the resumed turn; `--sandbox` defaults to `read-only`)
3. Never start a new session when continuing the same task

## Key Parameters

### --sandbox
| Mode | When to Use |
|------|-------------|
| `read-only` (default) | Plan review, code audit, Q&A: Codex reads but cannot write files |
| `workspace-write` | Implementation: Codex writes files in the project directory |

Approval is always `never` (set in the review profile); commands run inside the sandbox without prompting.

### --role FILE
Prepends a persona or constraints file to the prompt. Use the absolute installed path (for example `~/.claude/skills/plan-codex/codex-analyzer-role.md`): a bare filename is read relative to the project directory and will not be found. Add "Be concise. Output result only, no reasoning process." to the prompt itself.

### Model
Set once in `~/.codex/review.config.toml` (the `review` profile). Never pass `-m` anywhere.

## Prompting Best Practices

1. **Termination signals**: Ask Codex for a structured verdict with optional severity lines; the loop exits only on a round whose reply is exactly `VERDICT: APPROVED` with zero findings at any severity, or whose every finding was dropped through discussion. A `VERDICT: BLOCKED` or `VERDICT: WARNING` reply that lists no finding is not clean and not actionable: send ONE follow-up asking it to list its findings, and treat a repeat that still lists none as no verdict
2. **Feedback verbatim**: When sending review feedback via `--resume`, quote specific issues exactly. Do not summarize.
3. **Concise responses**: Always instruct Codex to be concise to save tokens
4. **No iteration cap**: Review loops have no round cap and no severity floor. Round 6, 10 or 20 continues the same way while accepted findings remain, and a round with only HIGH, only MEDIUM or only LOW findings is fixed and re-reviewed like a CRITICAL one. Preferences and false positives end through discussion with the active reviewer (via `--resume` when Codex is the reviewer; only an authorized reviewer's recorded concession drops a finding), never a round count. A review that errors, times out or returns no verdict (including a nonempty reply with no, several or an invalid `VERDICT:` line) is never an approval. Read the error, fix the cause, then retry or switch to another independent reviewer (a fresh Codex thread without `--resume`, or, when Codex is over its usage limit or returns no verdict, `~/.claude/config/scripts/reviewer.sh S <context-file> <out-file>` (built by the Review context paragraph: task requirements, review instructions, carried and contested findings, then the sanitized diff), a Sonnet review that needs no Codex quota; the work stays pending until some reviewer returns a clean verdict on the current head). Keep going until a verdict arrives; there is no retry count (owner mandate 2026-11-12). When the verdict comes from a fresh Codex thread, its new `THREAD_ID` replaces the saved reviewer `THREAD_ID` only (never an implementation `THREAD_ID`) for every later review `--resume`. Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. A finding you contest is settled only by an authorized reviewer's concession or verification, recorded in writing with its evidence (a Codex thread when one is available; when a fallback reviewer is the active reviewer, any reviewer authorized for the repo, tier S included, with no Codex thread required). Stop and report the work as UNREVIEWED only for a specific blocker Claude cannot resolve itself, such as missing credentials or every reviewer being unavailable for a reason the error text names (a call that merely died, timed out or returned nothing, even several times in a row, is never a blocker: keep retrying and switching reviewers), and name the blocker when you do A reviewer that asks for the same kind of thing every round (for example the tracking marker a repo rule such as REVIEW.md requires) is not looping or unsatisfiable: satisfy what it cites and re-review. Never conclude the reviewer is stuck, never report that no clean round was reached and never hand the user a keep-going-or-drop-it decision; a doubt about a finding is raised with the active reviewer (in the same Codex thread when Codex is the reviewer), and the only other exit is the failed-review rule. A `reviewer.sh` call yields a verdict only when the call itself exits 0: a nonzero exit is no verdict whatever it printed, even a `VERDICT: APPROVED` line (the installed reviewer.sh can print one after its model call failed), so check the exit status of the call and treat a nonzero exit as a failed review. A reviewer result counts only when the command exited 0 AND the output parses as a verdict under the Validate the response grammar. Anything else is no verdict.

**Review input (every reviewer call)**: every reviewer, the Codex call above and the tier S fallback below alike, is handed ONE input, built exactly as below after the intent-to-add step for the files this task created, and never the output of a fresh `git diff` run by the reviewer or by you. The diff goes through `~/.claude/config/scripts/redact-diff.sh`, a best-effort mask of inline credential values (private key blocks, cloud and API tokens, Bearer tokens, JWTs, password and secret assignments) on top of the path exclusions, not a guarantee, and the paths stay excluded. Only the masked output `.claude/review/review-input.diff` is ever placed in a prompt or a context file. Codex runs locally with read access to the working tree, so redaction governs what we put in the prompt, not what a local tool could open. If the script is missing or exits non-zero, or the diff is empty, the file is removed and nothing is dispatched to any reviewer, Codex or fallback: there is no verdict and the work stays unreviewed. Rebuild it before every round so it holds the CURRENT diff. Run it unchanged:

```
if R="$(git rev-parse --show-toplevel)" && [ -n "$R" ]; then (cd "$R" || exit 1
mkdir -p .claude/review; rm -f .claude/review/review-input.diff
(set -o pipefail; git diff HEAD -- ':(top)' ':(top,exclude,glob,icase)**/.env*' ':(top,exclude,glob,icase)**/*secret*' ':(top,exclude,glob,icase)**/*credential*' ':(top,exclude,glob,icase)**/*.pem' ':(top,exclude,glob,icase)**/*.key' ':(top,exclude).claude/review' | ~/.claude/config/scripts/redact-diff.sh > .claude/review/review-input.diff) && [ -s .claude/review/review-input.diff ] && echo "review input ready: send the contents of .claude/review/review-input.diff to every reviewer" || { rm -f .claude/review/review-input.diff; echo "no review input (the diff or its redaction failed, or the diff is empty): do NOT dispatch any reviewer, fix the cause and run this again"; }
); else echo "no repo root (git rev-parse --show-toplevel failed): do NOT dispatch any reviewer, run this again from inside the repository"; fi
```

**Review context (every reviewer call)**: every reviewer, the Codex call and the tier S fallback alike, is handed ONE file, `.claude/review/review-context.txt` at the repository top, built exactly as below and never a bare diff. The Codex call (`codex-call.sh`) sends it as the prompt with `--prompt-file` (a new call and every `--resume` call alike; never the prompt as a command argument, because a large diff exceeds the operating system's argument limit and Codex would never start), and `reviewer.sh S` takes the same file as its context, so the primary and the fallback reviewer judge the same requirements and the same bytes. It holds, in order: the task requirements you write into it (the task or plan text, every task of a multi-task run, so the reviewer can judge whether the change satisfies what was asked and not only whether it is correct), the review or audit instructions (for a test audit, its Evaluate list), every carried finding (raised in an earlier round and still open) and every contested finding with your reasoning, then the review input: the contents of `.claude/review/review-input.diff` (the Review input paragraph), the same masked bytes every reviewer receives, never a second `git diff` and never the raw diff. The text you write (requirements, instructions, findings) goes through the same `~/.claude/config/scripts/redact-diff.sh` as the diff (in its `--text` mode, which treats the input as plain text, so a private key block in the requirements is masked too), so the same best-effort mask of inline credential values applies to it, with the same limits: it masks private key blocks, cloud and API tokens, Bearer tokens, JWTs and password and secret assignments on any line, it is not a guarantee, and a secret in a shape it does not know passes through, so still write the requirements without any secret, credential or `.env` value. The text part is never typed into a shell command (r22 finding 1: a pasted line such as `EOF`, a command substitution or a backtick would otherwise end the heredoc early or run as shell): write it with your file-writing tool (Write, never a heredoc, echo or printf carrying the pasted text) to `.claude/review/requirements.raw.txt` at the repository top, as three sections in this order, each starting with its title on its own line: `TASK REQUIREMENTS:` (the task requirements, written without any secret, credential or `.env` value), `REVIEW INSTRUCTIONS:` (the review or audit instructions: the prompt text of this round, with its appended line) and `OPEN FINDINGS:` (every carried and contested finding with your reasoning, or the word none). The shell block below contains none of that text: it masks the raw file with `--text`, adds the `DIFF:` title and appends the review input, then deletes the raw file, so a stale one is never reused. A missing or empty raw file means no context is sent and no reviewer is called. Rebuild the file for every round so it holds the CURRENT diff and the current findings, and dispatch only after it prints "review context ready". If the review input is missing or empty, or the redaction fails, the context file is deleted and no context is sent, so no reviewer is called, there is no verdict and the work stays unreviewed.

```
R="$(git rev-parse --show-toplevel)" || R=""
CTX="$R/.claude/review/review-context.txt"
[ -n "$R" ] && rm -f "$CTX"
RAW="$R/.claude/review/requirements.raw.txt"
if [ -n "$R" ] && [ -s "$R/.claude/review/review-input.diff" ] && [ -s "$RAW" ] && ~/.claude/config/scripts/redact-diff.sh --text < "$RAW" > "$CTX" && printf '\nDIFF:\n' >> "$CTX"
then cat "$R/.claude/review/review-input.diff" >> "$CTX" && rm -f "$RAW" && echo "review context ready: $CTX" || { rm -f "$CTX"; echo "the review context could not be built: no context is sent"; }
else [ -n "$R" ] && rm -f "$CTX"; echo "the review input .claude/review/review-input.diff or the requirements file .claude/review/requirements.raw.txt is missing or empty, or the redaction failed: no context is sent"; fi
```

