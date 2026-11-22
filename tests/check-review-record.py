# Usage: check-review-record.py <repo> <base-sha>
# Exit 0 when <repo>/.claude/review/final-review.txt records a CLEAN review of the diff the run ended with.
# The record is what the execute-codex and tdd-execute-codex skills prescribe after every code-reviewer round (a Claude agent, so the
# wrapper log never sees its verdict): line 1 is `REVIEWED-DIFF: <sha256 of the reviewed diff>`, the rest is the reviewer's reply verbatim.
# WHY recompute the diff here: the hash is only evidence if it is derived from the final tree by the same command the skill prescribes, so a
# record written for an earlier round (a file changed afterwards) or for some other diff fails as stale.
# WHY a throwaway index: new files reach the reviewer's diff only through `git add -N`; running that here on a COPY of the index adds the
# untracked files the run never added, without touching the repo, and a skill that forgot the step still fails on the hash.
import hashlib, os, re, shutil, subprocess, sys, tempfile
import wlog
repo, base = sys.argv[1], sys.argv[2]
rec = os.path.join(repo, ".claude", "review", "final-review.txt")
try:
    lines = open(rec, encoding="utf-8").read().splitlines()
except OSError:
    print("no review record at .claude/review/final-review.txt", file=sys.stderr); sys.exit(1)
m = re.fullmatch(r"REVIEWED-DIFF: ([0-9a-f]{64})", lines[0].strip()) if lines else None
if not m:
    print("first line is not REVIEWED-DIFF: <sha256>", file=sys.stderr); sys.exit(1)
if wlog.verdict_state("\n".join(lines[1:])) != "clean":
    print("the recorded reply is not a clean verdict (APPROVED with zero findings)", file=sys.stderr); sys.exit(1)
# WHY the record path is excluded from the diff (r11 finding 3): the skill writes the record AFTER hashing, so a tracked or intent-to-add record would sit inside the hashed diff and change it on every write,
# leaving every record stale. The skill's hash command excludes the same path; both must, or they disagree.
SECRET = re.compile(r"(^|/)\.env[^/]*$|secret|credential|\.pem$|\.key$", re.I)
# WHY every git call is checked (r12 finding 3): a failed diff prints nothing, and the SHA-256 of nothing is a value a record can carry, so an unchecked exit status could validate an approval
# of a diff that was never computed. Any nonzero exit fails the check with the command and git's own message.
def git(*a, env=None):
    r = subprocess.run(["git", "-C", repo] + list(a), capture_output=True, env=env)
    if r.returncode != 0:
        print("git %s failed (exit %d): %s" % (" ".join(a[:2]), r.returncode, r.stderr.decode(errors="replace").strip()[:200]), file=sys.stderr); sys.exit(1)
    return r
idx = git("rev-parse", "--git-path", "index").stdout.decode().strip()
idx = idx if os.path.isabs(idx) else os.path.join(repo, idx)
with tempfile.TemporaryDirectory() as td:
    tmpidx = os.path.join(td, "index")
    if os.path.exists(idx):
        shutil.copy(idx, tmpidx)
    env = dict(os.environ, GIT_INDEX_FILE=tmpidx)
    new = [p for p in git("ls-files", "--others", "--exclude-standard", "-z").stdout.decode().split("\0") if p and not p.startswith(".claude/") and not SECRET.search(p)]
    for p in new:
        git("add", "-N", "--", p, env=env)
    diff = git("diff", base, "--", ":(top)", ":(top,exclude,glob,icase)**/.env*", ":(top,exclude,glob,icase)**/*secret*", ":(top,exclude,glob,icase)**/*credential*", ":(top,exclude,glob,icase)**/*.pem", ":(top,exclude,glob,icase)**/*.key", ":(top,exclude).claude/review/final-review.txt", env=env).stdout
# WHY an empty diff never validates: nothing changed means nothing was reviewed, so no record can approve it, whatever hash it carries.
if not diff.strip():
    print("the final diff is empty: nothing was reviewed", file=sys.stderr); sys.exit(1)
if hashlib.sha256(diff).hexdigest() != m.group(1):
    print("the record's diff hash is not the hash of the final diff (stale record)", file=sys.stderr); sys.exit(1)
sys.exit(0)
