# Usage: check-proof-permissions.py <review-loop-proof.sh>
# Exit 0 when the headless `claude -p` call in the proof runs with a permission mode that lets the session rewrite an existing plan file under .claude/.
# WHY (cc11 real run at bd3bce6 ended UNREVIEWED): claude 2.1.323 -p denies Edit, Write and a Bash redirect on an existing .claude/ file in acceptEdits, whatever
# Edit(...) allow rules are given; only bypassPermissions lets the fix of a plan through. A real session prompts the user, who approves; the proof must approve too.
import re, sys
src = open(sys.argv[1]).read()
calls = re.findall(r"^claude -p .*?(?=\n[^\n]*&& claude_rc=0)", src, re.M | re.S)
if len(calls) != 1:
    print("REJECT: expected exactly one headless claude -p call in the proof, found %d" % len(calls), file=sys.stderr); sys.exit(1)
m = re.search(r"--permission-mode (\S+)", calls[0])
if not m or m.group(1) != "bypassPermissions":
    print("REJECT: the proof session runs with permission mode %s, which denies edits to an existing .claude/plan file" % (m.group(1) if m else "default"), file=sys.stderr); sys.exit(1)
