# Usage: check-snapshot-hermetic.py <review-snapshot.sh> <variant>. Exit 0 only when, under that git configuration, the snapshot bytes equal the
# no-config baseline AND an edit made afterwards still changes them. variant "list" prints every variant name.
# WHY (r29): the snapshot hash is the evidence that the reviewed state is the final state, so no repo setting, user setting or environment
# variable may change what the script prints. Each variant injects ONE kind of setting in the repo's own config, the repo-local attributes
# file or the environment (global config is off in the harness, so the setting must be explicit to take effect at all).
import hashlib, os, shutil, subprocess, sys, tempfile

snap = os.path.abspath(sys.argv[1])
which = sys.argv[2]
BASE_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
BASE_ENV.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")

def run(repo, *a, env=None, inp=None):
    return subprocess.run(["git", "-C", repo] + list(a), env=env or BASE_ENV, capture_output=True, text=True, input=inp, check=True).stdout

def w(repo, name, text):
    os.makedirs(os.path.dirname(os.path.join(repo, name)) or repo, exist_ok=True)
    open(os.path.join(repo, name), "w", encoding="utf-8", newline="").write(text)

def fixture(dst):
    run(dst, "init", "-q")
    w(dst, "app.py", "alpha = 1111\nbeta = 2\ngamma = 3\n")
    w(dst, "old.py", "def helper():\n    return 'same body kept so a rename is detectable'\n\nprint(helper())\n")
    w(dst, "other.py", "x = 1\n")
    w(dst, "sub/mod.py", "y = 1\n")
    run(dst, "add", "-A")
    tree = run(dst, "write-tree").strip()
    base = run(dst, "commit-tree", tree, inp="base\n").strip()
    run(dst, "update-ref", "HEAD", base)
    w(dst, "app.py", "alpha = 2222\nbeta = 2\ngamma = 3\nalpha = 2222\n")  # repeated lines: algorithm settings could reorder hunks
    w(dst, "other.py", "x = 2\n")
    w(dst, "sub/mod.py", "y = 2\n")
    os.remove(os.path.join(dst, "old.py"))
    w(dst, "renamed.py", "def helper():\n    return 'same body kept so a rename is detectable'\n\nprint(helper())\n")  # untracked: delete + add looks like a rename
    w(dst, "café.py", "z = 1\n")  # non-ASCII name: core.quotePath changes how git prints it
    return base

def snapshot(repo, base, env=None):
    r = subprocess.run([snap, base], cwd=repo, env=env or BASE_ENV, capture_output=True)
    if r.returncode != 0:
        print("snapshot exited %d: %s" % (r.returncode, r.stderr.decode("utf-8", "replace")[:300]))
        sys.exit(3)
    return r.stdout

def cfg(*kv):
    def f(repo):
        for i in range(0, len(kv), 2):
            run(repo, "config", kv[i], kv[i + 1])
        return None
    return f

def attrs(text, *kv):
    def f(repo):
        open(os.path.join(repo, ".git", "info", "attributes"), "w").write(text)
        for i in range(0, len(kv), 2):
            run(repo, "config", kv[i], kv[i + 1])
        return None
    return f

def orderfile(repo):
    open(os.path.join(repo, ".git", "order.txt"), "w").write("sub/mod.py\nother.py\n")
    run(repo, "config", "diff.orderFile", os.path.join(repo, ".git", "order.txt"))

def envvar(**kv):
    return lambda repo: dict(BASE_ENV, **kv)

VARIANTS = {
    "baseline-repeat": lambda repo: None,
    "diff.external that prints nothing": cfg("diff.external", "true"),
    "textconv driver via attributes that prints nothing": attrs("*.py diff=nothing\n", "diff.nothing.textconv", "true"),
    "diff.noprefix=true": cfg("diff.noprefix", "true"),
    "diff.mnemonicPrefix=true": cfg("diff.mnemonicPrefix", "true"),
    "color.ui=always": cfg("color.ui", "always", "color.diff", "always"),
    "diff.context=0": cfg("diff.context", "0"),
    "diff.interHunkContext=20": cfg("diff.interHunkContext", "20"),
    "GIT_EXTERNAL_DIFF in the environment": envvar(GIT_EXTERNAL_DIFF="true"),
    "GIT_DIFF_OPTS=--unified=0 in the environment": envvar(GIT_DIFF_OPTS="--unified=0"),
    "core.quotePath=false with a non-ASCII filename": cfg("core.quotePath", "false"),
    "diff.renames=copies": cfg("diff.renames", "copies"),
    "diff.algorithm=patience": cfg("diff.algorithm", "patience"),
    "diff.indentHeuristic=false": cfg("diff.indentHeuristic", "false"),
    "diff.orderFile": orderfile,
    "diff.relative=true": cfg("diff.relative", "true"),
    "core.abbrev=40": cfg("core.abbrev", "40"),
    "core.autocrlf=true": cfg("core.autocrlf", "true"),
    "diff.submodule=log": cfg("diff.submodule", "log"),
    "diff.ignoreSubmodules=all": cfg("diff.ignoreSubmodules", "all"),
    "diff.wsErrorHighlight=all": cfg("diff.wsErrorHighlight", "all"),
    "diff.colorMoved=zebra with color.ui=always": cfg("diff.colorMoved", "zebra", "color.ui", "always"),
    "diff.suppressBlankEmpty=true": cfg("diff.suppressBlankEmpty", "true"),
}
# Documented residual: a repo-local `-diff` attribute makes git print "Binary files differ" instead of the text, so the bytes MAY differ from
# the baseline, but the `index <old>..<new>` line (full ids, from --full-index) still changes on any edit. This variant therefore only
# requires the edit-changes-the-hash half.
RESIDUAL = {"-diff attribute (rendering changes, edits must still change the hash)": attrs("*.py -diff\n")}

if which == "list":
    print("\n".join(list(VARIANTS) + list(RESIDUAL)))
    sys.exit(0)
table = dict(VARIANTS, **RESIDUAL)
if which not in table:
    print("unknown variant")
    sys.exit(2)

with tempfile.TemporaryDirectory() as d:
    ref = os.path.join(d, "ref"); os.mkdir(ref)
    base = fixture(ref)
    baseline = snapshot(ref, base)
    if not baseline or b"+alpha = 2222" not in baseline or "caf".encode() not in baseline:
        print("baseline snapshot is not the expected content")
        sys.exit(4)
    repo = os.path.join(d, "var")
    shutil.copytree(ref, repo, symlinks=True)
    env = table[which](repo)
    out = snapshot(repo, base, env)
    if which not in RESIDUAL and out != baseline:
        print("snapshot bytes differ from the no-config baseline (%d vs %d bytes)" % (len(out), len(baseline)))
        sys.exit(1)
    w(repo, "app.py", "alpha = 3333\nbeta = 2\ngamma = 3\nalpha = 3333\n")  # same size as before, different bytes
    after = snapshot(repo, base, env)
    if hashlib.sha256(after).digest() == hashlib.sha256(out).digest():
        print("an edit after the snapshot did not change the hash")
        sys.exit(1)
