# Usage: check-approval-sites.py [tests-dir]. Exit 0 when every checker script that judges a review verdict either decides "ended approved" through wlog.final_review_state
# or says why it is not an approval decision with a line `# APPROVAL-EXEMPT: <reason>`.
# WHY (r25): each checker used to filter the log its own way before picking the final review, so one kind of attempt (a failed Codex call after a clean fallback review) could be filtered
# out of the very list that decides. A new checker that grades a verdict must take the shared function or justify itself in writing; this rule makes forgetting fail loudly.
import glob, os, re, sys
d = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
JUDGES = re.compile(r"wlog\.(is_clean|valid_verdict|verdict_state)\(|\[-1\]\[\"exit\"\]|evs\[-1\]|last\[\"exit\"\]")
bad = []
for f in sorted(glob.glob(os.path.join(d, "*.py"))):
    name = os.path.basename(f)
    if name in ("wlog.py", "evlog.py", "check-approval-sites.py"):
        continue
    t = open(f, encoding="utf-8").read()
    if JUDGES.search(t) and "wlog.final_review_state(" not in t and not re.search(r"^# APPROVAL-EXEMPT: \S", t, re.M):
        bad.append("%s: judges a review verdict but neither calls wlog.final_review_state nor carries an '# APPROVAL-EXEMPT: <reason>' line" % name)
print("\n".join(bad), file=sys.stderr)
sys.exit(1 if bad else 0)
