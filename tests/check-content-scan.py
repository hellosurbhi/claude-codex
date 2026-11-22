# Usage: check-content-scan.py <skill-file>   exit 0 when the tier R gate the skill prescribes really refuses and allows what it must.
# WHY (cc11-main-r4 finding 1): tier R (CodeRabbit) reads committed content itself, so redacting the supplied diff protects nothing and a filename check misses an inline key in an ordinary
# source file. The skill therefore prescribes TWO checks: the secret-shaped-path check (prints nothing) and this content scan of the added lines (exit status exactly 1). This extracts BOTH
# exact commands from the skill text and runs them with bash on throwaway repos from a subdirectory, so a missing, reworded or cwd-relative clause fails here instead of passing on wording.
import os, re, subprocess, sys, tempfile
text = open(sys.argv[1], encoding="utf-8").read()
pm = re.search(r"`(git diff --name-only <base commit>\.\.HEAD -- [^`]*)`", text)
sm = re.search(r"`(d=\$\(git diff <base commit>\.\.HEAD -- ':\(top\)'\) && [^`]*)`", text)
if not pm or not sm:
    print("path check or content scan command not found in %s" % sys.argv[1]); sys.exit(1)
def allowed(d, sub, base):
    """tier R is allowed only when the path check prints nothing AND the scan exits with exactly 1"""
    cwd = os.path.join(d, sub)
    p = subprocess.run(["bash", "-c", pm.group(1).replace("<base commit>", base)], cwd=cwd, capture_output=True, text=True)
    s = subprocess.run(["bash", "-c", sm.group(1).replace("<base commit>", base)], cwd=cwd, capture_output=True, text=True)
    return (p.stdout.strip() == "" and p.returncode == 0 and s.returncode == 1), p.stdout.split(), s.returncode
with tempfile.TemporaryDirectory() as d:
    g = lambda *a: subprocess.run(("git", "-C", d, "-c", "user.email=a@b", "-c", "user.name=n") + a, capture_output=True, text=True, check=True).stdout
    g("init", "-q")
    def commit(msg):
        # WHY plumbing: the global pre-commit hooks must not run inside a throwaway fixture repo.
        tree = g("write-tree").strip(); par = subprocess.run(["git", "-C", d, "rev-parse", "-q", "--verify", "HEAD"], capture_output=True, text=True).stdout.strip()
        g("update-ref", "HEAD", g(*(["commit-tree", tree, "-m", msg] + (["-p", par] if par else []))).strip())
    def add(name, body):
        os.makedirs(os.path.dirname(os.path.join(d, name)) or d, exist_ok=True); open(os.path.join(d, name), "w").write(body); g("add", "-f", name)
    add("README", "r"); add("app/seed.txt", "s"); commit("base")
    bad = []
    def case(label, want, files, base=None):
        b = base or g("rev-parse", "HEAD").strip()
        for n, body in files: add(n, body)
        commit(label)
        ok, paths, rc = allowed(d, "app", base or b)
        if ok != want: bad.append("%s: tier R allowed=%s, expected %s (path check printed %s, scan exit %s)" % (label, ok, want, paths, rc))
    case("clean diff", True, [("app/clean.js", "const a = 1;\nconst note = 'hello';\n")])
    case("inline key in a normal .js file", False, [("app/api.js", "const apiKey = \"abcd1234efgh5678ijkl\";\n")])
    case("secret-shaped path", False, [("app/Secrets.json", "{}")])
    for label, body in (("private key block", "-----BEGIN RSA PRIVATE KEY-----\n"), ("AWS key id", "id AKIAABCDEFGHIJKLMNOP\n"),
                        ("GitHub token", "t ghp_" + "a" * 36 + "\n"), ("GitHub fine-grained token", "t github_pat_11ABC\n"), ("sk- key", "k sk-" + "a" * 24 + "\n"),
                        ("Slack token", "t xoxb-123\n"), ("Google key", "k AIza" + "a" * 35 + "\n"), ("single-quoted password", "PASSWORD: 'correct-horse-battery'\n")):
        case("added %s" % label, False, [("app/%s.js" % label.replace(" ", "_"), body)])
    # a REMOVED credential line must not block (only added lines count) and a short placeholder value is not credential-shaped
    base = g("rev-parse", "HEAD").strip(); g("rm", "-q", "-f", "app/api.js"); commit("removed key"); ok, _, rc = allowed(d, "app", base)
    if not ok: bad.append("deleting a credential line was refused (scan exit %s)" % rc)
    case("short placeholder value", True, [("app/cfg.js", "const token = 'x';\n")])
    # unresolvable base: the scan must not exit 1
    ok, _, rc = allowed(d, "app", "0" * 40)
    if ok: bad.append("unresolvable base commit: tier R allowed (scan exit %s)" % rc)
    if bad:
        print("\n".join(bad)); sys.exit(1)
print("ok")
