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

def commit_all(dst, msg="base\n"):
    run(dst, "add", "-A")
    tree = run(dst, "write-tree").strip()
    c = run(dst, "commit-tree", tree, inp=msg).strip()
    run(dst, "update-ref", "HEAD", c)
    return c

def fixture(dst, sub=False):
    run(dst, "init", "-q")
    w(dst, "keep/untouched.py", "k = 1\n")
    if sub:  # a real nested repo with one commit; `git add -A` records it as a gitlink (submodule-style entry)
        v = os.path.join(dst, "vend"); os.makedirs(v)
        run(v, "init", "-q"); w(v, "lib.py", "lib = 1\n"); commit_all(v, "vend base\n")
    w(dst, "app.py", "alpha = 1111\nbeta = 2\ngamma = 3\n")
    w(dst, "old.py", "def helper():\n    return 'same body kept so a rename is detectable'\n\nprint(helper())\n")
    w(dst, "other.py", "x = 1\n")
    w(dst, "sub/mod.py", "y = 1\n")
    base = commit_all(dst)
    w(dst, "app.py", "alpha = 2222\nbeta = 2\ngamma = 3\nalpha = 2222\n")  # repeated lines: algorithm settings could reorder hunks
    w(dst, "other.py", "x = 2\n")
    w(dst, "sub/mod.py", "y = 2\n")
    os.remove(os.path.join(dst, "old.py"))
    w(dst, "renamed.py", "def helper():\n    return 'same body kept so a rename is detectable'\n\nprint(helper())\n")  # untracked: delete + add looks like a rename
    w(dst, "café.py", "z = 1\n")  # non-ASCII name: core.quotePath changes how git prints it
    return base

def snapshot(repo, base, env=None, allow_fail=False):
    r = subprocess.run([snap, base], cwd=repo, env=env or BASE_ENV, capture_output=True)
    if allow_fail:
        return r
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

# State variants (r30): the USER'S INDEX LIES (assume-unchanged, skip-worktree, split index, caches) or the repo holds things a stat-cache diff cannot bind
# (filters, submodules, nested repos, global ignores). Each setup returns a spec: env, contains, absent, fail (the snapshot must exit non-zero with empty
# stdout and this text in stderr), sub (use the fixture that has a submodule). With neither contains/absent/fail the bytes must equal the baseline.
FINAL_APP = "alpha = 2222\nbeta = 2\ngamma = 3\nalpha = 2222\n"

def S(**kw):
    return kw

def st_assume(repo):
    run(repo, "update-index", "--assume-unchanged", "app.py", "other.py", "sub/mod.py")
    return S()
def st_skipwt(repo):
    run(repo, "update-index", "--skip-worktree", "app.py", "other.py")
    return S()
def st_caches(repo):
    run(repo, "config", "core.untrackedCache", "true"); run(repo, "config", "core.fsmonitor", "true")
    run(repo, "update-index", "--split-index")
    return S()
def st_sparse_absent(repo):
    run(repo, "update-index", "--skip-worktree", "keep/untouched.py"); os.remove(os.path.join(repo, "keep", "untouched.py"))
    return S()
def st_sparse_config(repo):
    run(repo, "config", "core.sparseCheckout", "true")
    open(os.path.join(repo, ".git", "info", "sparse-checkout"), "w").write("/*\n!keep/\n")
    return st_sparse_absent(repo)
def st_staged_then_edited(repo):
    w(repo, "app.py", "alpha = 9999\nbeta = 2\ngamma = 3\nalpha = 9999\n"); run(repo, "add", "app.py"); w(repo, "app.py", FINAL_APP)
    return S()
def st_global_excludes(repo):
    open(os.path.join(repo, ".git", "gex"), "w").write("renamed.py\n"); run(repo, "config", "core.excludesFile", os.path.join(repo, ".git", "gex"))
    return S()
def st_xdg_ignore(repo):
    x = os.path.join(repo, ".git", "xdg"); os.makedirs(os.path.join(x, "git")); open(os.path.join(x, "git", "ignore"), "w").write("renamed.py\n")
    return S(env=dict(BASE_ENV, XDG_CONFIG_HOME=x))
def st_info_exclude(repo):
    open(os.path.join(repo, ".git", "info", "exclude"), "w").write("renamed.py\n")  # repo-local ignore rules ARE repo state: applied on purpose
    return S(absent=[b"renamed.py"])
def st_filemode(repo):
    run(repo, "config", "core.fileMode", "false"); os.chmod(os.path.join(repo, "other.py"), 0o755)
    return S(contains=[b"new mode 100755"])
def st_symlink(repo):
    os.symlink("app.py", os.path.join(repo, "link.py"))
    return S(contains=[b"new file mode 120000", b"+app.py"])
def st_symlink_cfg(repo):
    run(repo, "config", "core.symlinks", "false")
    return st_symlink(repo)
def st_deleted(repo):
    os.remove(os.path.join(repo, "other.py"))
    return S(contains=[b"deleted file mode"])
def st_tracked_ignored(repo):
    w(repo, ".gitignore", "keep/\n"); w(repo, "keep/untouched.py", "k = 2\n")
    return S(contains=[b"+k = 2"])
def st_filter(repo):
    open(os.path.join(repo, ".git", "info", "attributes"), "w").write("*.py filter=scrub\n"); run(repo, "config", "filter.scrub.clean", "cat")
    return S(fail="filter")
def st_lfs(repo):
    open(os.path.join(repo, ".git", "info", "attributes"), "w").write("*.py filter=lfs\n")
    return S(fail="filter")
def st_sub_clean(repo):
    return S(sub=True)
def st_sub_dirty(repo):
    w(os.path.join(repo, "vend"), "lib.py", "lib = 2\n")
    return S(sub=True, fail="vend")
def st_sub_untracked(repo):
    w(os.path.join(repo, "vend"), "new.py", "n = 1\n")
    return S(sub=True, fail="vend")
def st_sub_moved(repo):
    v = os.path.join(repo, "vend"); w(v, "lib.py", "lib = 2\n"); newc = commit_all(v, "vend two\n")
    return S(sub=True, contains=[b"-Subproject commit ", b"+Subproject commit " + newc.encode()])
def st_nested(repo):
    n = os.path.join(repo, "nest"); os.makedirs(n); run(n, "init", "-q"); w(n, "z.py", "z = 1\n")
    return S(fail="nest")

STATE = {
    "assume-unchanged files edited on disk": st_assume,
    "skip-worktree files edited on disk": st_skipwt,
    "untrackedCache, fsmonitor and split index set": st_caches,
    "sparse checkout: a skip-worktree file absent by design is not a deletion": st_sparse_absent,
    "sparse checkout configured with a sparse-checkout file": st_sparse_config,
    "a file staged and then edited again": st_staged_then_edited,
    "core.excludesFile ignoring a new file": st_global_excludes,
    "XDG global ignore file ignoring a new file": st_xdg_ignore,
    ".git/info/exclude is repo state and applies": st_info_exclude,
    "core.fileMode=false with an executable-bit change": st_filemode,
    "an added symlink": st_symlink,
    "an added symlink with core.symlinks=false": st_symlink_cfg,
    "a tracked file deleted on disk": st_deleted,
    "a tracked file edited under a .gitignore rule": st_tracked_ignored,
    "a clean-filter attribute fails closed": st_filter,
    "an LFS filter attribute fails closed": st_lfs,
    "a clean submodule adds nothing": st_sub_clean,
    "a dirty submodule fails closed": st_sub_dirty,
    "an untracked file inside a submodule fails closed": st_sub_untracked,
    "a clean submodule pointer change shows as the gitlink change": st_sub_moved,
    "an untracked nested git repository fails closed": st_nested,
}

def tree_state(repo):
    # WHY status first and with optional locks off: `git status` refreshes (rewrites) the index, which would make this probe change what it measures.
    e = dict(BASE_ENV, GIT_OPTIONAL_LOCKS="0")
    st = run(repo, "status", "--porcelain=v1", env=e)
    objs = sum(len(f) for _, _, f in os.walk(os.path.join(repo, ".git", "objects")))
    idx = hashlib.sha256(open(os.path.join(repo, ".git", "index"), "rb").read()).hexdigest()
    return (idx, objs, run(repo, "rev-parse", "HEAD"), run(repo, "for-each-ref"), st)

UNTOUCHED = "the snapshot leaves the real index, refs and object store byte-identical"

if which == "list":
    print("\n".join(list(VARIANTS) + list(RESIDUAL) + list(STATE) + [UNTOUCHED]))
    sys.exit(0)
table = dict(VARIANTS, **RESIDUAL)
if which not in table and which not in STATE and which != UNTOUCHED:
    print("unknown variant")
    sys.exit(2)

with tempfile.TemporaryDirectory() as d:
    def build(name, sub):
        r = os.path.join(d, name); os.mkdir(r)
        b = fixture(r, sub)
        return r, b, snapshot(r, b)
    if which == UNTOUCHED:
        ref, base, _ = build("ref", False)
        before = tree_state(ref); snapshot(ref, base); after = tree_state(ref)
        if before != after:
            print("the real repository changed: %r vs %r" % (before, after)); sys.exit(1)
        sys.exit(0)
    sub = False
    if which in STATE:
        spec0 = None
    ref, base, baseline = build("ref", False)
    if not baseline or b"+alpha = 2222" not in baseline or "caf".encode() not in baseline:
        print("baseline snapshot is not the expected content")
        sys.exit(4)
    if which in STATE:
        # the submodule fixture is built when the setup asks for it, so probe with a throwaway copy
        probe = os.path.join(d, "probe"); shutil.copytree(ref, probe, symlinks=True)
        sub = bool(STATE[which](probe).get("sub"))
        if sub:
            ref, base, baseline = build("refsub", True)
    repo = os.path.join(d, "var")
    shutil.copytree(ref, repo, symlinks=True)
    spec = None
    if which in STATE:
        spec = STATE[which](repo)
        env = spec.get("env")
    else:
        env = table[which](repo)
    if spec and spec.get("fail"):
        r = snapshot(repo, base, env, allow_fail=True)
        if r.returncode == 0 or r.stdout or spec["fail"].encode() not in r.stderr:
            print("expected a fail-closed exit naming %r, got rc=%d stdout=%d bytes stderr=%r" % (spec["fail"], r.returncode, len(r.stdout), r.stderr[:200]))
            sys.exit(1)
        sys.exit(0)
    out = snapshot(repo, base, env)
    if spec and (spec.get("contains") or spec.get("absent")):
        for c in spec.get("contains", []):
            if c not in out:
                print("snapshot lacks %r" % c); sys.exit(1)
        for c in spec.get("absent", []):
            if c in out:
                print("snapshot holds %r" % c); sys.exit(1)
    elif which not in RESIDUAL and out != baseline:
        print("snapshot bytes differ from the no-config baseline (%d vs %d bytes)" % (len(out), len(baseline)))
        sys.exit(1)
    w(repo, "app.py", "alpha = 3333\nbeta = 2\ngamma = 3\nalpha = 3333\n")  # same size as before, different bytes
    after = snapshot(repo, base, env)
    if hashlib.sha256(after).digest() == hashlib.sha256(out).digest():
        print("an edit after the snapshot did not change the hash")
        sys.exit(1)
