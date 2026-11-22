# Usage: check-proof-permissions.py <review-loop-proof.sh>
# Exit 0 only when the proof's headless `claude -p` call can rewrite an existing plan file under .claude/ AND is confined while doing so.
# WHY (cc11): claude 2.1.323 -p denies Edit, Write and a Bash redirect on an existing .claude/ file in acceptEdits whatever allow rules are given, so the real scenario
# runs with prompts off (bypassPermissions). That is only acceptable with the deny-by-default PreToolUse hook (tests/proof-confine-hook.py) wired in, a start-up probe
# that must see the hook deny an out-of-bounds call, and a fresh out dir. Each missing piece has its own REJECT line so a test can assert the exact cause.
import re, sys
src = open(sys.argv[1]).read()
def reject(why):
    print("REJECT: " + why, file=sys.stderr); sys.exit(1)
calls = re.findall(r"^claude -p .*?(?=\n[^\n]*&& claude_rc=0)", src, re.M | re.S)
if len(calls) != 1 or '"${perm[@]}"' not in calls[0] or "--permission-mode" in calls[0]:
    reject("expected exactly one headless claude -p call that takes its permission flags only from the perm array")
m = re.search(r'if \[\[ \$scenario == real \]\]; then\n(.*?)\nelse\n(.*?)\nfi\n(?=claude -p)', src, re.S)
if not m:
    reject("the permission flags are not split into a real branch and an other-scenarios branch")
real_b, other_b = m.group(1), m.group(2)
if "--permission-mode bypassPermissions" in other_b:
    reject("bypassPermissions must be limited to the real scenario")
pm = re.search(r"--permission-mode (\S+)", real_b)
if not pm or pm.group(1) != "bypassPermissions":
    reject("the proof session runs with permission mode %s, which denies edits to an existing .claude/plan file" % (pm.group(1) if pm else "default"))
if "proof-confine-hook.py" not in real_b or '--settings "$out/proof-settings.json"' not in real_b or '"PreToolUse"' not in real_b or '"matcher":".*"' not in real_b:
    reject("bypassPermissions without the confinement hook wired through --settings as a PreToolUse hook on every tool")
if '[[ ! -f "$hook" || ! -x "$hook" ]]' not in real_b:
    reject("no start-up refusal when the confinement hook is missing or not executable")
if not re.search(r'!= deny \|\| .*!= allow \]\].*exit 2', real_b):
    reject("no start-up probe that requires the hook to deny an out-of-bounds call")
if "-e \"$4\"" not in src or "exit 2" not in src[src.index('-e "$4"'):src.index('-e "$4"') + 220]:
    reject("the real scenario does not insist on creating its own fresh out dir")
if "the confinement hook ran" not in src:
    reject("no check that the hook logged at least one decision")
