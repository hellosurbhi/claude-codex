# Usage: check-content-scan.py <skill-file>   exit 0 when the tier R gate the skill prescribes really refuses and allows what it must.
# WHY (cc11-main-r4 finding 1): tier R (CodeRabbit) reads committed content itself, so redacting the supplied diff protects nothing and a filename check misses an inline key in an ordinary
# source file. The skill therefore prescribes TWO checks: the secret-shaped-path check (prints nothing) and this content scan of the added lines (exit status exactly 1). This extracts BOTH
# exact commands from the skill text and runs them with bash on throwaway repos from a subdirectory, so a missing, reworded or cwd-relative clause fails here instead of passing on wording.
import os, re, subprocess, sys, tempfile
text = open(sys.argv[1], encoding="utf-8").read()
pm = re.search(r"`(git diff --name-only [^`]*<base commit>\.\.HEAD -- [^`]*)`", text)
sm = re.search(r"`(d=\$\(git diff [^`]*<base commit>\.\.HEAD -- ':\(top\)'\) && [^`]*)`", text)
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
        os.makedirs(os.path.dirname(os.path.join(d, name)) or d, exist_ok=True); open(os.path.join(d, name), "wb" if isinstance(body, bytes) else "w").write(body); g("add", "-f", name)
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
    # round 5: the scan covers the WHOLE payload (added, removed and context lines), so removing a credential or leaving it on an unchanged line next to a change is still refused.
    def refused(label, setup):
        base = g("rev-parse", "HEAD").strip(); setup(); commit(label); ok, paths, rc = allowed(d, "app", base)
        if ok: bad.append("%s: tier R allowed (path check printed %s, scan exit %s)" % (label, paths, rc))
    key = "const apiKey = \"abcd1234efgh5678ijkl\";\n"
    add("app/r5del.js", key + "x\n"); commit("seed removal")
    refused("deleted credential line", lambda: add("app/r5del.js", "x\n"))
    add("app/r5ctx.js", "a\n" + key + "".join("filler %d\n" % i for i in range(60)) + "z\n"); commit("seed context")
    refused("credential on an unchanged context line next to a change", lambda: add("app/r5ctx.js", "A\n" + key + "".join("filler %d\n" % i for i in range(60)) + "z\n"))
    refused("credential 60 lines away from the only change in the file", lambda: add("app/r5ctx.js", "A\n" + key + "".join("filler %d\n" % i for i in range(60)) + "Z\n"))
    add("app/r5old.txt", "ordinary\n"); add("app/Secrets.old", "x\n"); commit("seed paths")
    refused("deleted secret-shaped file", lambda: g("rm", "-q", "-f", "app/Secrets.old"))
    add("app/prod.pem", "x\n"); commit("seed pem")
    refused("secret-shaped file renamed away", lambda: (g("mv", "app/prod.pem", "app/prod.txt")))
    add("app/r5move.js", key); commit("seed move")
    refused("credential-bearing file renamed unchanged", lambda: g("mv", "app/r5move.js", "app/r5moved.js"))
    case("short placeholder value", True, [("app/cfg.js", "const token = 'x';\n")])
    # round 6: git omits or rewrites file contents in several ways (binary by attribute or by a NUL byte, -diff, textconv, an external diff driver, big files, submodules); the scan must still see the real bytes or refuse.
    def cfg(k, v): g("config", k, v)
    def uncfg(k): g("config", "--unset", k)
    keyline = "const apiKey = \"abcd1234efgh5678ijkl\";\n"
    add(".gitattributes", "app/r6bin*.js binary\napp/r6nodiff*.js -diff\napp/r6tc*.js diff=strip\n"); commit("attributes")
    refused("ordinary source file marked binary by .gitattributes, with an inline key", lambda: add("app/r6bin1.js", keyline))
    refused("file with a NUL byte and an inline key", lambda: add("app/r6nul.js", b"\0\0" + keyline.encode() + b"\0"))
    refused("file with the -diff attribute and an inline key", lambda: add("app/r6nodiff1.js", keyline))
    cfg("diff.strip.textconv", "sed -e 's/.*//'")
    refused("textconv driver that would strip the key", lambda: add("app/r6tc1.js", keyline)); uncfg("diff.strip.textconv")
    cfg("diff.external", "true")
    refused("external diff driver that prints nothing", lambda: add("app/r6ext.js", keyline)); uncfg("diff.external")
    cfg("core.bigFileThreshold", "1")
    refused("file over core.bigFileThreshold (git calls it binary) with an inline key", lambda: add("app/r6big.js", keyline)); uncfg("core.bigFileThreshold")
    cfg("color.ui", "always"); cfg("diff.wsErrorHighlight", "all")
    refused("colored diff with trailing whitespace after an inline key", lambda: add("app/r6color.js", keyline.rstrip("\n") + "   \n")); uncfg("color.ui"); uncfg("diff.wsErrorHighlight")
    def gitlink(name="app/r6sub"):
        g("update-index", "--add", "--cacheinfo", "160000,%s,%s" % ("a" * 40, name))
    refused("gitlink (submodule) change", gitlink)
    cfg("diff.ignoreSubmodules", "all")
    refused("gitlink change hidden by diff.ignoreSubmodules=all", lambda: gitlink("app/r6sub2")); uncfg("diff.ignoreSubmodules")
    cfg("diff.submodule", "log")
    refused("gitlink change shown as a log by diff.submodule=log", lambda: gitlink("app/r6sub3")); uncfg("diff.submodule")
    # the PATH check must also see a secret-shaped gitlink path that diff.ignoreSubmodules=all would hide
    cfg("diff.ignoreSubmodules", "all"); base = g("rev-parse", "HEAD").strip(); gitlink("app/secrets-sub"); commit("secret-shaped gitlink")
    if not allowed(d, "app", base)[1]: bad.append("path check missed a secret-shaped gitlink path under diff.ignoreSubmodules=all")
    uncfg("diff.ignoreSubmodules")
    # a genuine binary file with no credential keeps tier R available (invalid UTF-8 and NUL bytes must not make the scan fail)
    case("genuine binary file with no credential", True, [("app/r6photo.bin", bytes(range(256)) * 4 + b"\xff\xfe\0\x80")])
    # unresolvable base: the scan must not exit 1
    ok, _, rc = allowed(d, "app", "0" * 40)
    if ok: bad.append("unresolvable base commit: tier R allowed (scan exit %s)" % rc)
    if bad:
        print("\n".join(bad)); sys.exit(1)
print("ok")
