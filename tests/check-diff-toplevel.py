# Usage: check-diff-toplevel.py <skill-or-command-file>   exit 0 when every reviewer diff command in the file lists changes in sibling folders.
# WHY (cc11-main-r2 finding 3): `git diff HEAD -- .` is relative to the shell's cwd, so a review started from a subfolder silently dropped every
# change outside it (50 changed files became 2). The prescribed pathspec must start at the repository top (`:(top)`). This extracts each
# `git diff HEAD|$START_SHA -- ...` command from the file and runs it from one sibling folder of a throwaway repo with changes in two folders,
# plus a secret-named file that must stay out.
import os, re, shlex, subprocess, sys, tempfile
text = open(sys.argv[1], encoding="utf-8").read()
cmds = re.findall(r"`(git diff (?:HEAD|\$START_SHA) -- [^`]*)`", text)
if not cmds:
    print("no reviewer diff command in %s" % sys.argv[1]); sys.exit(1)
rc = 0
for c in cmds:
    with tempfile.TemporaryDirectory() as d:
        run = lambda *a, cwd=d: subprocess.run(("git", "-C", cwd, "-c", "user.email=a@b", "-c", "user.name=n") + a, capture_output=True, text=True, check=True).stdout
        run("init", "-q"); open(os.path.join(d, "README"), "w").write("r"); run("add", "README")
        # WHY plumbing: the global pre-commit hooks must not run inside a throwaway fixture repo.
        sha = run("commit-tree", run("write-tree").strip(), "-m", "i").strip(); run("update-ref", "HEAD", sha)
        for n in ("front/a.py", "back/b.py", "back/deep/c.py", "front/.env"):
            os.makedirs(os.path.dirname(os.path.join(d, n)), exist_ok=True); open(os.path.join(d, n), "w").write("1")
        run("add", "-N", "-f", "front/a.py", "back/b.py", "back/deep/c.py", "front/.env")
        argv = shlex.split(c.replace("$START_SHA", sha))
        out = sorted(subprocess.run(argv[:2] + ["--name-only"] + argv[2:], cwd=os.path.join(d, "front"), capture_output=True, text=True).stdout.split())
        if out != ["back/b.py", "back/deep/c.py", "front/a.py"]:
            print("from a subfolder %r printed %s" % (c[:50], out)); rc = 1
sys.exit(rc)
