# Usage: check-review-record.py <repo> <base-sha>
# APPROVAL-EXEMPT: validates the recorded reply of a Claude reviewer agent, which never appears in the wrapper log; it binds that record to the final diff hash instead
# Exit 0 when <repo>/.claude/review/final-review.txt records a CLEAN review of the diff the run ended with.
# The record is what the execute-codex and tdd-execute-codex skills prescribe after every code-reviewer round (a Claude agent, so the
# wrapper log never sees its verdict): line 1 is `REVIEWED-DIFF: <sha256 of the reviewed diff>`, the rest is the reviewer's reply verbatim.
# WHY recompute the diff here: the hash is only evidence if it is derived from the final tree by the same command the skill prescribes, so a
# record written for an earlier round (a file changed afterwards) or for some other diff fails as stale.
import hashlib, os, re, subprocess, sys
import wlog
repo, base = sys.argv[1], sys.argv[2]
# WHY the repo root, not the path as given (round 15 finding 2): the skills record at the repository root whatever folder the shell was in, so a checker handed a subfolder must read the same place.
# A failed lookup fails the check (never falls back to the given path, which could hold some other .claude/review).
_top = subprocess.run(["git", "-C", repo, "rev-parse", "--show-toplevel"], capture_output=True)
if _top.returncode != 0 or not _top.stdout.strip():
    print("git rev-parse --show-toplevel failed: cannot locate the review record", file=sys.stderr); sys.exit(1)
repo = _top.stdout.decode().strip()
rec = os.path.join(repo, ".claude", "review", "final-review.txt")
try:
    lines = open(rec, encoding="utf-8").read().splitlines()
except OSError:
    print("no review record at .claude/review/final-review.txt", file=sys.stderr); sys.exit(1)
m = re.fullmatch(r"REVIEWED-DIFF: ([0-9a-f]{64})", lines[0].strip()) if lines else None
if not m:
    print("first line is not REVIEWED-DIFF: <sha256>", file=sys.stderr); sys.exit(1)
# WHY the second line is exactly `redacted-snapshot` (r19 finding 1, replacing r17's raw-or-redacted choice): the hash is of the raw snapshot, but EVERY reviewer (the primary and the tier S fallback alike) is handed only that snapshot after redact-diff.sh, so a record that claims `raw-snapshot` describes a review the workflow no longer allows. The checker cannot know which reviewer ran, so it requires the one valid claim.
if len(lines) < 2 or lines[1].strip() != "REVIEWED-AS: redacted-snapshot":
    print("second line is not REVIEWED-AS: redacted-snapshot", file=sys.stderr); sys.exit(1)
if wlog.verdict_state("\n".join(lines[2:])) != "clean":
    print("the recorded reply is not a clean verdict (APPROVED with zero findings)", file=sys.stderr); sys.exit(1)
# WHY every snapshot failure fails the check (r12 finding 3, r28): a failed diff prints nothing, and the SHA-256 of nothing is a value a record can carry, so a nonzero exit of the script fails the check.
# WHY the shipped script, not a second implementation (r28 finding 2): the snapshot (tracked changes plus new-file diffs of untracked non-ignored files, without secret-named paths,
# .claude/review and .claude/plan) is defined once in scripts/review-snapshot.sh; the skills hash its output before and after the reviewer, and this check recomputes it with the same script.
_snap = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "review-snapshot.sh")
_r = subprocess.run([_snap, base], cwd=repo, capture_output=True)
if _r.returncode != 0:
    print("review-snapshot.sh failed (exit %d): %s" % (_r.returncode, _r.stderr.decode(errors="replace").strip()[:200]), file=sys.stderr); sys.exit(1)
diff = _r.stdout
# WHY an empty diff never validates: nothing changed means nothing was reviewed, so no record can approve it, whatever hash it carries.
if not diff.strip():
    print("the final diff is empty: nothing was reviewed", file=sys.stderr); sys.exit(1)
if hashlib.sha256(diff).hexdigest() != m.group(1):
    print("the record's diff hash is not the hash of the final diff (stale record)", file=sys.stderr); sys.exit(1)
sys.exit(0)
