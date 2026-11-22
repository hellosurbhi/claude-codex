# claude-codex

A Claude Code setup for collaborative AI development: Claude plans with Opus, Codex implements or reviews, Sonnet implements or reviews. Five skills (and their equivalent commands) drive a structured plan → implement → review loop.

## Skills (Recommended)

Skills are the primary interface. They support eval-based testing via skill-creator and are easier to iterate on than commands.

| Skill | Trigger | Description |
|-------|---------|-------------|
| `plan-codex` | `/plan-codex <task>` | Claude plans with Opus, Codex audits for correctness, completeness and security, re-auditing until no findings remain |
| `claude-codex` | `/claude-codex <task or plan>` | Claude implements, Codex reviews with APPROVED/WARNING/BLOCKED verdicts |
| `execute-codex` | `/execute-codex <task or plan>` | Smart size-based routing: Claude (small) or Codex (large) implements, code-reviewer reviews |
| `tdd-claude-codex` | `/tdd-claude-codex <task or plan>` | TDD: Claude writes tests, Codex audits tests, Claude implements, Codex reviews implementation |
| `tdd-execute-codex` | `/tdd-execute-codex <task or plan>` | TDD: Claude writes tests, Codex audits tests, smart routing for implementation, code-reviewer reviews |

Commands (`commands/`) are retained for backward compatibility — they support model pinning and explicit `allowed-tools` restrictions that skills cannot enforce.

## How It Works

```
/plan-codex <task>
  Claude Opus + Plan agent    → creates structured plan
  Codex audits the plan       → re-audits until a round has no findings
  Plan saved to .claude/plan/<feature>.md

/execute-codex <task or plan file>
  Small change (≤2 files, ≤30 lines) → Claude implements directly
  Large change                        → Codex implements
  feature-dev code-reviewer agent      → re-reviews until a round has no findings

/claude-codex <task or plan file>
  Claude implements (any model)       → Edit/Write + self-verify
  Codex reviews uncommitted changes   → returns structured verdict (APPROVED/WARNING/BLOCKED)
  Claude fixes findings               → fix and re-review at any severity until a clean round
```

## Dependencies

### 1. Claude Code

Install from [claude.ai/code](https://claude.ai/code).

### 2. OpenAI Codex CLI

```bash
npm install -g @openai/codex
```

Authenticate with your ChatGPT account (recommended):

```bash
codex login
```

Or with your OpenAI API key:

```bash
export OPENAI_API_KEY=your-key-here
```

The Codex wrapper (install step 3) also needs `python3` to read the Codex event stream. Check with `python3 --version`.

### 3. feature-dev plugin

This setup uses the `code-reviewer` agent from [claude-plugins-official](https://github.com/anthropics/claude-plugins-official).

Install the plugin in Claude Code:

```
claude plugin install feature-dev@claude-plugins-official
```

## Installation

### 1. Clone and copy files

```bash
git clone https://github.com/<your-username>/claude-codex
cd claude-codex

mkdir -p ~/.claude/skills ~/.claude/prompts ~/.claude/commands

cp -r skills/*   ~/.claude/skills/
cp -r prompts/*  ~/.claude/prompts/
cp -r commands/* ~/.claude/commands/   # optional: for model pinning / tool restrictions
```

### 2. Configure Codex

Suppress reasoning tokens by adding the following to `~/.codex/config.toml`:

```toml
hide_agent_reasoning = true
```

Note: this is a top-level key. If your `config.toml` already has `[table]` sections, add it above the first one (TOML keys appended after a table header belong to that table).

### 3. Install the Codex wrapper

Codex CLI 0.154.0 removed `codex mcp-server`, so there is no MCP server to add. The skills call `codex exec` through one wrapper script, `scripts/codex-call.sh` in this repo. Every skill calls it at one fixed path, so install it there:

```bash
mkdir -p ~/.claude/config/scripts
cp scripts/codex-call.sh ~/.claude/config/scripts/codex-call.sh
chmod +x ~/.claude/config/scripts/codex-call.sh
```

The diff redaction script is needed at one fixed path by every diff review, not only the fallback. It masks inline credential values (private keys, cloud and API tokens, Bearer tokens, JWTs, password and secret assignments) in the diff before it goes into any reviewer prompt, the Codex primary included. It is a best-effort mask on top of the path exclusions, not a guarantee, and Codex runs locally with read access to the working tree, so it limits what we put in the prompt, not what a local tool could open. If it is missing, no reviewer is called:

```bash
cp scripts/redact-diff.sh ~/.claude/config/scripts/redact-diff.sh
chmod +x ~/.claude/config/scripts/redact-diff.sh
```

The review snapshot script is needed at one fixed path too. It is the one definition of the state a reviewer judges and the review record certifies: `git diff <base>` of the tracked changes plus a new-file diff for every untracked, non-ignored file, without secret-named paths (`.env*`, `*secret*`, `*credential*`, `*.pem`, `*.key`) and without `.claude/review` and `.claude/plan`. The execute-codex and tdd-execute-codex skills hash it before the reviewer runs and again after the reply, so a new file created while the reviewer ran voids the round; the other diff skills build their review input from it. It prints nothing and exits non-zero when any step fails, and it never touches your real index, refs or object store: it builds the working-tree files into a fresh private index (started from your current index entries, never from the base, so a sparse-excluded or uninitialized path keeps its current committed state) and a temporary object directory and diffs that tree against the base, so no flag or cache in your index (assume-unchanged, skip-worktree, racy timestamps, fsmonitor) can hide an edit. It stops with an error naming the path when a file has a filter attribute (clean filters, LFS), when a submodule or nested git repository has uncommitted changes, when the index holds an unmerged conflict, or when a path has a newline in its name; your global ignore file is not applied, only the repo's own ignore rules. Every git setting that shapes its output is pinned inside the script (external diff helpers, textconv, colour, prefixes, context, rename detection, algorithm, quoting), so one repo or user config cannot change the bytes that get hashed; the checker and the review-record tests call it too, rather than their own `git diff`.

```bash
cp scripts/review-snapshot.sh ~/.claude/config/scripts/review-snapshot.sh
chmod +x ~/.claude/config/scripts/review-snapshot.sh
```

The usage-limit fallback also needs the shared reviewer script `~/.claude/config/scripts/reviewer.sh` (it is not shipped in this repo, and it needs its own `claude` CLI). Without it a Codex quota error leaves the review unreviewed instead of falling back.

Outside reviewers (Gemini, CodeRabbit) are never called from these skills, because a skill cannot prove a diff is free of credentials; they run only inside the reviewer script's own chain. When Codex gives no verdict (a usage limit, an error or a malformed reply), the skills fall back to exactly one reviewer, tier S (`reviewer.sh S`, a Sonnet review) on one context file that carries the task requirements, the review instructions, the carried and contested findings and then the sanitized diff (a plan audit carries the audit instructions, the findings and then the current plan text), and the work stays pending until it returns a clean verdict on the current head.

The wrapper sends the prompt to Codex on stdin, from `--prompt-file FILE` (the skills always use this for reviews, because a large diff as one command argument exceeds the operating system's limit and Codex would never start) or from a short positional prompt. A missing or empty prompt file is an error: nothing is called and there is no verdict. The positional form is unchanged, so this is backward compatible and the contract stays v3.

A Codex stream that contains any error or turn.failed event, before or after the completed turn, is a failed call: nothing is printed on stdout (no verdict) and the diagnostics go to stderr. This tightens which streams count as success without changing the command line, so the contract stays v3.

`scripts/redact-diff.sh` refuses a diff it cannot read line by line: an unknown hunk-line prefix (for example from `git diff --output-indicator-old=X`), an unknown header line or hunk counts that disagree with the `@@` header exit nonzero with nothing on stdout, so a caller sends nothing instead of a guessed mask. This stays `redact-diff v2` because nothing is pushed or installed yet and every caller already treats a nonzero status as "send nothing". `scripts/review-snapshot.sh` pins the three `--output-indicator-*` flags, and `tests/check-snapshot-config-keys.py` sets every key in `git help -c` (one at a time, several values each, minus sections the script never reaches) and fails if any changes the snapshot bytes; it found and pinned `core.bigFileThreshold` and `core.ignoreStat` on git 2.43.

Every shipped script carries its contract on its second line, so one rule finds it: `scripts/codex-call.sh` is `codex-call v3`, `scripts/redact-diff.sh` is `redact-diff v2` and `scripts/review-snapshot.sh` is `review-snapshot v1`. The tests fail when any of them moves or this line goes stale.

The second line of `scripts/codex-call.sh` is a contract line (`# contract: codex-call v3 ...`). It names this repo as the source of truth, and a copy installed elsewhere is only compatible with the skills while that line matches. v3 made the argument parser strict: every option needs its value, an unknown option or an extra argument exits 2 with the usage line, and a prompt that starts with a dash must follow `--`; the documented invocations are unchanged, so only malformed calls that v2 ran or half-ran now stop. Setting `CODEX_CALL_EVENT_LOG` to a file path (used only by the test proof, unset in normal use) makes the wrapper append one `wrapper-failed` line for any non-zero exit that never reached codex, so a failed attempt after a clean review cannot leave that review standing. It is additive and off by default, so the contract stays v3.

Every skill validates a reviewer reply with one grammar. The first non-blank line must be exactly `VERDICT: APPROVED`, `VERDICT: WARNING` or `VERDICT: BLOCKED`. Severity lines are optional, `none` and `n/a` placeholders are ignored, a severity header with empty text takes the next non-blank line that is not a header as its text, and with none (end of output, or another header next) the output is no verdict, never clean, any real finding at any severity means findings whatever the verdict word and empty or unparseable output is no verdict. A bare `VERDICT: APPROVED` is a clean review.

Without the `codex-call.sh` wrapper or the `codex` CLI (the two things each skill's availability check inspects; it does not look at `reviewer.sh`), the check fails: `/plan-codex`, `/claude-codex` and the final review in `/tdd-claude-codex` stop and say Codex is unavailable, while `/execute-codex` and `/tdd-execute-codex` fall back to Claude implementing directly. Both TDD skills skip the Codex test audit.

Put the model in a `review` profile at `~/.codex/review.config.toml` (one file per profile in Codex 0.164+):

```toml
model = "<newest model your plan offers>"
model_reasoning_effort = "xhigh"
approval_policy = "never"
```

Available models depend on your Codex plan, account type and CLI version (`~/.codex/models_cache.json` lists them).

### 4. Verify

```bash
~/.claude/config/scripts/codex-call.sh "Reply with the single word OK"
```

It prints `THREAD_ID: <id>` then `OK`.

## Usage

### Planning

```
/plan-codex Add JWT authentication to the API
```

Claude Opus uses the built-in `Plan` agent to research your codebase and produce a structured plan. Codex audits it for correctness, security, and completeness. The approved plan is saved to `.claude/plan/<feature>.md`.

### Execution (Codex implements, Sonnet reviews)

```
/execute-codex .claude/plan/jwt-auth.md
```

Or skip the plan step for a direct task:

```
/execute-codex Fix the null pointer in user.service.ts
```

Claude routes automatically:
- **Small change** (≤2 files, ≤30 lines, no new logic) — Claude implements directly, Sonnet reviews
- **Large change**: Codex implements, Sonnet reviews and feeds back until a round has no findings

### Execution (Claude implements, Codex reviews)

```
/claude-codex .claude/plan/jwt-auth.md
```

Or for a direct task:

```
/claude-codex Add input validation to the registration endpoint
```

Claude implements using the active model (default: Sonnet; override with `/model opus` for heavier tasks). Codex reviews the uncommitted diff via `codex exec`, returning a structured verdict (APPROVED / WARNING / BLOCKED):
- **Any accepted finding at any severity** (CRITICAL, HIGH, MEDIUM or LOW, under any verdict): Claude fixes it, verifies with tests/lint and Codex re-reviews
- **Done** only when a round lists no accepted findings; there is no round cap, so round 6 and beyond continue while findings remain
- **Failed review** (error, timeout, no verdict): never an approval. Claude fixes the cause and retries, or switches to another reviewer, until a verdict arrives. The changes are reported UNREVIEWED only for a named blocker it cannot clear (missing credentials, every reviewer unavailable)

### Model Override

Commands have defaults (`plan-codex` → Opus, `execute-codex` → Sonnet). Override per session:

```
/model opus
/execute-codex .claude/plan/complex-feature.md
```

## File Structure

```
~/.claude/
├── skills/
│   ├── codex-mcp/
│   │   ├── SKILL.md                  # Auto-loaded Codex usage knowledge
│   │   └── reference.md              # Detailed patterns and examples
│   ├── plan-codex/
│   │   ├── SKILL.md                  # /plan-codex skill
│   │   ├── codex-analyzer-role.md    # Bundled Codex role for plan auditing
│   │   └── evals/evals.json          # Eval scenarios for skill-creator
│   ├── claude-codex/
│   │   ├── SKILL.md                  # /claude-codex skill
│   │   └── evals/evals.json
│   ├── execute-codex/
│   │   ├── SKILL.md                  # /execute-codex skill
│   │   ├── codex-architect-role.md   # Bundled Codex role for implementation
│   │   └── evals/evals.json
│   ├── tdd-claude-codex/
│   │   ├── SKILL.md                  # /tdd-claude-codex skill
│   │   ├── codex-analyzer-role.md    # Bundled Codex role for test auditing
│   │   ├── tdd-specialist-role.md    # Bundled TDD specialist role for test writing
│   │   └── evals/evals.json
│   └── tdd-execute-codex/
│       ├── SKILL.md                  # /tdd-execute-codex skill
│       ├── codex-architect-role.md   # Bundled Codex role for implementation
│       ├── tdd-specialist-role.md    # Bundled TDD specialist role for test writing
│       └── evals/evals.json
├── commands/                         # Deprecated — retained for backward compatibility
│   ├── plan-codex.md
│   ├── execute-codex.md
│   ├── claude-codex.md
│   ├── tdd-claude-codex.md
│   └── tdd-execute-codex.md
├── prompts/
│   └── codex/
│       ├── analyzer.md      # Codex role: plan auditor (source for skill bundles)
│       ├── architect.md     # Codex role: implementer (source for skill bundles)
│       └── reviewer.md      # Codex role: code reviewer
└── config/
    └── scripts/
        ├── codex-call.sh            # codex exec wrapper every skill calls (install step 3)
        ├── redact-diff.sh           # masks credential values in the diff every reviewer receives (install step 3)
        └── review-snapshot.sh       # the reviewed state: tracked changes plus untracked files, hashed by the review record (install step 3)
```

The tests are not installed. They live in this repository only:

```
tests/
├── review-loop-proof.sh # runs a real headless Claude session through a skill with a scripted reviewer
├── proof-confine-hook.py # deny-by-default PreToolUse hook that confines the `real` proof to its scratch repo
├── fake-codex-call.sh   # the scripted reviewer: one finding per round, tied to repo state
├── spy-reviewer.sh      # real fallback reviewer for the usage-limit scenario (no ~/.claude writes)
├── shim/codex           # logging `codex` shim put first on PATH in the real scenario (skill and wrapper untouched)
├── evlog.py, wlog.py, treehash.py   # wrapper event log: one JSON line per real execution; the checkers read only this
├── test-mirrors.py      # skill and command copies must carry identical review-loop clauses
└── test-checkers.sh     # unit cases for the checkers (no Claude, no network)
```

CI (`.github/workflows/ci.yml`) runs on pull requests and pushes to `main`. It syntax-checks every shell script, runs `python3 tests/test-mirrors.py .` and runs `CHECKERS_NO_SPY=1 bash tests/test-checkers.sh`. It then runs `bash tests/check-no-spy-tripwire.sh`, which repeats that suite in a HOME whose installed `reviewer.sh`, `codex-call.sh` and friends (and `codex`, `gemini`, `coderabbit`, `claude` first on PATH) are tripwires, and fails if any of them was executed: with `CHECKERS_NO_SPY=1` nothing outside the repo runs. That variable runs the suite without the private `reviewer.sh`: only the cases written as `expect_spy`, which call the spy reviewer or assert on its output, are skipped and counted, and a self-test fails if a case that needs no reviewer was skipped. Run the same command locally to reproduce CI.

`tests/review-loop-proof.sh <skills-dir|installed> <claude-codex|plan-codex|execute-codex|tdd-claude-codex|tdd-execute-codex|codex-mcp> <scenario> [empty-out-dir]` proves the loop has no round cap and no severity floor. Scenarios: `round6`, `high-only`, `medium-only`, `low-only` (every scripted round is fixed, round 6 is reached in `round6` and the run ends on a clean re-review of the final state), `failed` and `malformed` (dead, empty, verdict-less, duplicate-verdict and invalid-verdict replies are followed by more calls until a verdict arrives), `usage-limit` (Codex reports a usage limit with a reset time on every call; a real fallback reviewer, `tests/spy-reviewer.sh`, must review the actual change and return a clean verdict; for execute-codex and tdd-execute-codex the quota fallback is also the spy: on a Codex quota error Claude implements directly and the last review after the quota hit must be a clean spy review bound to the final `.py` code state; only the execute-codex task asks for four modules (`mathops.py`, `strops.py`, `listops.py`, `pkginfo.py`) and checks that all four were built, while the tdd-execute-codex task builds `add(a, b)` in `app.py`) and `real` (no fake: the installed `codex-call.sh` and real Codex, checking a THREAD_ID, a verdict and a `--resume` follow-up on the same thread; for execute-codex, where Codex implements rather than reviews, the verdict check is dropped and the follow-up only has to return on the same thread). `installed` loads the skills from `~/.claude/skills` instead of copying a source folder. The output directory must be empty (for `real` it must not exist yet, the proof creates it). The `real` scenario runs an agent with permission prompts off, confined by the PreToolUse hook `tests/proof-confine-hook.py` to its scratch repo (no interpreter, no command or variable expansion outside single quotes, writes only inside the repo and never under `.git`, `codex-call.sh` only with a read-only sandbox, every option parsed by the wrapper's own grammar); the run refuses to start unless that hook is present, executable and denies an out-of-bounds probe call. Each run is a real Claude session, so it uses API quota. For the execute-codex and tdd-execute-codex loops, where a code-reviewer agent does the review, in the scripted scenarios the harness tells that agent to relay the scripted reviewer (not in `real` or `usage-limit`).

The `prompts/codex/` files are passed via `--role` on each Codex call to shape its behaviour per phase.

## Credits

- `prompts/codex/` role prompts (`analyzer.md`, `architect.md`, `reviewer.md`) are sourced from [ccg-workflow](https://github.com/fengshao1227/ccg-workflow) by fengshao1227, licensed under MIT.
- TDD specialist prompt adapted from [everything-claude-code](https://github.com/affaan-m/everything-claude-code) by affaan-m, licensed under MIT. `code-reviewer` agent from [claude-plugins-official/feature-dev](https://github.com/anthropics/claude-plugins-official).

## Notes

- Plans are saved to `.claude/plan/` in your project directory — add to `.gitignore` if you don't want them committed
- No iteration cap on any review loop: every loop runs until a round has no accepted findings at any severity, and a failed review leaves the work UNREVIEWED
- The `codex-mcp` skill auto-loads when Codex calls are relevant, providing Claude with session management patterns and best practices
- `/claude-codex` uses `codex exec` for review: Codex receives one masked review context file (TASK REQUIREMENTS, REVIEW INSTRUCTIONS, OPEN FINDINGS and the redacted DIFF) via `--prompt-file`, never runs git itself and returns a structured verdict only, minimising token usage
