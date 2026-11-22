# Usage: check-diff-toplevel.py <skill-or-command-file>   exit 0 when the file builds its reviewer diff with scripts/review-snapshot.sh and that script lists changes in sibling folders.
# WHY (cc11-main-r2 finding 3): `git diff HEAD -- .` is relative to the shell's cwd, so a review started from a subfolder silently dropped every
# change outside it (50 changed files became 2). Since r28 the snapshot (pathspec included) is defined once in scripts/review-snapshot.sh, so this
# check has two halves: the file must call that script for every snapshot (never an inline `git diff <base> -- ':(top)' ...` of its own), and the
# script, run from one sibling folder of a throwaway repo with changes in two folders, must list both folders and leave a secret-named file out.
import os, re, subprocess, sys, tempfile
text = open(sys.argv[1], encoding="utf-8").read()
here = os.path.dirname(os.path.abspath(__file__))
snap = os.path.join(here, "..", "scripts", "review-snapshot.sh")
calls = re.findall(r"scripts/review-snapshot\.sh (?:HEAD|\"\$\{START_SHA:\?\}\"|\$START_SHA)", text)
if not calls:
    print("no reviewer diff command in %s: it must call ~/.claude/config/scripts/review-snapshot.sh" % sys.argv[1]); sys.exit(1)
if re.search(r"git diff (?:HEAD|\"\$\{START_SHA:\?\}\"|\$START_SHA) -- ", text):
    print("%s builds a reviewer diff inline instead of calling review-snapshot.sh" % sys.argv[1]); sys.exit(1)
with tempfile.TemporaryDirectory() as d:
    run = lambda *a, cwd=d: subprocess.run(("git", "-C", cwd, "-c", "user.email=a@b", "-c", "user.name=n") + a, capture_output=True, text=True, check=True).stdout
    run("init", "-q"); open(os.path.join(d, "README"), "w").write("r"); run("add", "README")
    # WHY plumbing: the global pre-commit hooks must not run inside a throwaway fixture repo.
    sha = run("commit-tree", run("write-tree").strip(), "-m", "i").strip(); run("update-ref", "HEAD", sha)
    # tracked-and-modified, intent-to-add and plain untracked files in two folders, plus a secret-named file
    for n in ("front/a.py", "back/b.py", "back/deep/c.py", "front/.env"):
        os.makedirs(os.path.dirname(os.path.join(d, n)), exist_ok=True); open(os.path.join(d, n), "w").write("1")
    run("add", "-N", "-f", "front/a.py", "front/.env")
    out = subprocess.run([snap, sha], cwd=os.path.join(d, "front"), capture_output=True, text=True)
    files = sorted(set(re.findall(r"(?m)^diff --git a/(\S+) b/", out.stdout)))
    if out.returncode != 0 or files != ["back/b.py", "back/deep/c.py", "front/a.py"]:
        print("from a subfolder review-snapshot.sh printed %s (exit %d)" % (files, out.returncode)); sys.exit(1)
sys.exit(0)
