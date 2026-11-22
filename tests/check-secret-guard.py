# Usage: check-secret-guard.py <skill-file>   exit 0 when the secret guard the skill prescribes before `reviewer.sh R` really works.
# WHY (cc11-main-r2 finding 2): tier R (CodeRabbit) reads the repository's commits itself and ignores the sanitized input file, so a
# committed .env change would reach an outside service. The skill therefore has the agent run `git diff --name-only <base>..HEAD -- <pathspecs>`
# first and use tier S when it prints anything. This extracts that exact command from the skill text and runs it in a throwaway repo, FROM A
# SUBDIRECTORY, so a clause that is missing, misspelled or cwd-relative fails here instead of passing on wording alone.
import os, re, shlex, subprocess, sys, tempfile
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"`(git diff --name-only [^`]*<base commit>\.\.HEAD -- [^`]*)`", text)
if not m:
    print("no `git diff --name-only --no-renames <base commit>..HEAD -- ...` guard found in %s" % sys.argv[1]); sys.exit(1)
with tempfile.TemporaryDirectory() as d:
    g = lambda *a, cwd=d: subprocess.run(("git", "-C", cwd, "-c", "user.email=a@b", "-c", "user.name=n") + a, capture_output=True, text=True, check=True).stdout
    g("init", "-q")
    def commit(msg):
        # WHY plumbing: the global pre-commit hooks must not run inside a throwaway fixture repo.
        tree = g("write-tree").strip(); par = subprocess.run(["git", "-C", d, "rev-parse", "-q", "--verify", "HEAD"], capture_output=True, text=True).stdout.strip()
        args = ["commit-tree", tree, "-m", msg] + (["-p", par] if par else [])
        g("update-ref", "HEAD", g(*args).strip())
    open(os.path.join(d, "README"), "w").write("r"); g("add", "README"); commit("base"); base = g("rev-parse", "HEAD").strip()
    secrets = [".env", "app/.env.local", "cfg/Secrets.json", "deploy_credentials.yml", "k/id.pem", "app/b.KEY"]
    for n in secrets + ["app/okay.py"]:
        os.makedirs(os.path.dirname(os.path.join(d, n)) or d, exist_ok=True); open(os.path.join(d, n), "w").write("1")
    g("add", "-f", *(secrets + ["app/okay.py"])); commit("change")
    cmd = shlex.split(m.group(1).replace("<base commit>", base))
    got = sorted(subprocess.run(cmd, cwd=os.path.join(d, "app"), capture_output=True, text=True).stdout.split())
    missing = sorted(set(secrets) - set(got))
    if missing or "app/okay.py" in got:
        print("guard run from a subdirectory missed %s (printed %s)" % (missing, got)); sys.exit(1)
    # a change with no secret-named file must print nothing, so tier R stays available
    base2 = g("rev-parse", "HEAD").strip()
    open(os.path.join(d, "app", "other.py"), "w").write("2"); g("add", "app/other.py"); commit("clean")
    clean = shlex.split(m.group(1).replace("<base commit>", base2))
    out = subprocess.run(clean, cwd=os.path.join(d, "app"), capture_output=True, text=True).stdout.split()
    if out:
        print("guard printed for a clean change: %s" % out); sys.exit(1)
print("ok")
