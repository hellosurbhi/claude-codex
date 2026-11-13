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

Without it, each skill's availability check fails: `/plan-codex`, `/claude-codex` and the final review in `/tdd-claude-codex` stop and say Codex is unavailable, while `/execute-codex` and `/tdd-execute-codex` fall back to Claude implementing directly. Both TDD skills skip the Codex test audit.

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
- **Large change** — Codex implements, Sonnet reviews and feeds back until a round has no findings

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
├── scripts/
│   └── codex-call.sh        # codex exec wrapper every skill calls (install step 3)
└── tests/
    ├── review-loop-proof.sh # runs a real headless Claude session through a skill with a scripted reviewer
    └── fake-codex-call.sh   # the scripted reviewer: one finding per round, tied to repo state
```

`tests/review-loop-proof.sh <skills-dir|installed> <claude-codex|plan-codex> <round6|high-only|medium-only|low-only|failed|malformed>` proves the loop has no round cap and no severity floor: it passes only when every scripted round is fixed, round 6 is reached in the `round6` scenario, the run ends on a clean re-review, and in the `failed` scenario two dead calls (and in `malformed` an empty, verdict-less, duplicate-verdict and invalid-verdict reply) are followed by more calls until a verdict arrives. The output directory must be empty. Each run is a real Claude session, so it uses API quota.

The `prompts/codex/` files are passed via `--role` on each Codex call to shape its behaviour per phase.

## Credits

- `prompts/codex/` role prompts (`analyzer.md`, `architect.md`, `reviewer.md`) are sourced from [ccg-workflow](https://github.com/fengshao1227/ccg-workflow) by fengshao1227, licensed under MIT.
- TDD specialist prompt adapted from [everything-claude-code](https://github.com/affaan-m/everything-claude-code) by affaan-m, licensed under MIT. `code-reviewer` agent from [claude-plugins-official/feature-dev](https://github.com/anthropics/claude-plugins-official).

## Notes

- Plans are saved to `.claude/plan/` in your project directory — add to `.gitignore` if you don't want them committed
- No iteration cap on any review loop: every loop runs until a round has no accepted findings at any severity, and a failed review leaves the work UNREVIEWED
- The `codex-mcp` skill auto-loads when Codex calls are relevant, providing Claude with session management patterns and best practices
- `/claude-codex` uses `codex exec` for review — Codex runs `git diff HEAD` itself and returns a structured verdict only, minimising token usage
