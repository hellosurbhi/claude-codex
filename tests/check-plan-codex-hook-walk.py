# Usage: check-plan-codex-hook-walk.py <plan-codex SKILL.md or command> <proof-confine-hook.py> <scratch repo root> <git baseline file>
# Exit 0 when EVERY shell command the file prescribes (each fenced block, and each inline command that starts with a script path, `test -x` or `codex --version`) is ALLOWED by the confinement hook
# when run alone from the scratch repo root. Exit 1 names each denied command. Exit 2 when the extractor finds fewer commands than the file is known to prescribe (it must not pass by finding none).
# WHY (cc11 r64 finding 2): the hook was tested only against hand-picked commands, so the skill told the model to run an inline umask/chmod and a trapped subshell that the hook denies, and a real run that
# needed the fallback could not follow its own skill. Walking the prescription itself makes the skill and the hook unable to drift apart unnoticed.
import json, os, re, subprocess, sys
skill, hook, root, base = sys.argv[1:5]
text = open(skill, encoding="utf-8").read()
SUB = {"<feature-name>": "feat", "<out-file>": ".claude/review/out.txt", "<context-file>": ".claude/review/ctx.txt"}
def fill(c):
    for k, v in SUB.items():
        c = c.replace(k, v)
    return c
cmds = [fill(b) for b in re.findall(r"```[a-z]*\n(.*?)\n```", text, re.S) if not b.lstrip().startswith(("/execute-codex", "/"))]
inline = re.findall(r"`([^`\n]+)`", text)
cmds += [fill(c) for c in inline if re.match(r"(?:~/\.claude/config/scripts/[a-z-]+\.sh [A-Za-z<]|test -x ~/|codex --version$|(?:R=|umask |mkdir |chmod |trap |git |rm |cat |ls )\S)", c) and "<THREAD_ID>" not in c]
cmds = list(dict.fromkeys(c for c in cmds if c.strip()))
# the two codex-call.sh forms the skill describes in prose (a flag list and a prompt), written out in full
cmds += ['~/.claude/config/scripts/codex-call.sh --sandbox read-only --role ~/.claude/skills/plan-codex/codex-analyzer-role.md "audit the plan at .claude/plan/feat.md"',
         '~/.claude/config/scripts/codex-call.sh --sandbox read-only --resume 01a20563-33aa-73d3-95b8-a8e2d30ab187 "re-audit the plan"']
if len(cmds) < 7:
    print("extractor found only %d commands: %s" % (len(cmds), cmds)); sys.exit(2)
bad = []
for c in cmds:
    inp = json.dumps({"tool_name": "Bash", "cwd": root, "tool_input": {"command": c}})
    p = subprocess.run([sys.executable, hook], input=inp, capture_output=True, text=True, env=dict(os.environ, PROOF_SCRATCH_ROOT=root, PROOF_GIT_BASELINE=base))
    try:
        d = json.loads(p.stdout)["hookSpecificOutput"]
    except Exception:
        bad.append((c, "no decision: " + p.stderr[:120])); continue
    if d["permissionDecision"] != "allow":
        bad.append((c, d.get("permissionDecisionReason", "")))
for c, why in bad:
    print("DENIED: %r -> %s" % (c[:160], why[:200]))
sys.exit(1 if bad else 0)
