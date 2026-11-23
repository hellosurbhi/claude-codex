#!/usr/bin/env python3
# Usage: check-snapshot-config-keys.py <review-snapshot.sh> [--self-check]
# Exit 0 only when NO git configuration key can change the bytes review-snapshot.sh prints (it either prints the baseline bytes or fails closed
# with empty stdout and a nonzero status).
# WHY an enumeration and not a hand-kept list (r33): the script pins the settings its author thought of, and the next setting nobody thought of
# silently changes the bytes the redactor and the hash depend on. This test takes git's OWN list of config names (`git help -c`), sets each one,
# one at a time, to several non-default values, and compares. A key a newer git adds shows up in that list and is tested the moment the installed
# git is upgraded; a key this git does not know is ignored by git, so the test tolerates it. (Git 2.43 has NO config key for the three
# --output-indicator flags, so this test cannot flag them; they are pinned as flags and covered by the redactor's fail-closed checks.)
# HOW a key is set: written into the repository's own .git/config of a fresh copy of the test repo (the script clears GIT_CONFIG_COUNT/KEY/VALUE and the global and system
# files on purpose, so the environment channel no longer reaches it). A repo-local value loses only to the script's own `-c` pins. Each key and value gets its own copy, so keys still run in parallel.
# FILTER: every section in `git help -c` is exercised EXCEPT the sections in DENY, whose commands this script never runs (it runs ls-files,
# update-index, write-tree, ls-tree, diff, check-attr, rev-parse, hash-object and cat-file only). A new section on a newer git is exercised by
# default; only an explicit entry in DENY skips one.
# WILDCARD keys (diff.<driver>.textconv, filter.<name>.clean, ...) are expanded with one representative name.
# VALUES: a key's type is not known, so each key gets several: true, false, 0, 99, an odd string, always, never, three diff algorithms, /dev/null,
# a colour. A value of the wrong type makes git refuse the key, a nonzero exit with empty stdout, the same fail-closed outcome.
# --self-check: copies the script with the diff.context pin and -U3 removed and requires this test to FLAG diff.context, proving it can fail.
import os, re, shutil, subprocess, sys, tempfile, threading
from concurrent.futures import ThreadPoolExecutor

NONET = "no network"
DENY = {  # section -> why this script never reaches it
    "gc": "no gc runs", "maintenance": "no gc", "pack": "no pack written", "merge": "no merge", "mergetool": "no merge", "difftool": "no difftool",
    "rerere": "no merge", "rebase": "no rebase", "sequence": "no rebase", "stash": "no stash", "am": "no am", "revert": "no revert",
    "http": NONET, "remote": NONET, "fetch": NONET, "push": NONET, "pull": NONET, "receive": NONET, "transfer": NONET, "uploadpack": NONET,
    "uploadarchive": NONET, "credential": NONET, "ssh": NONET, "sendpack": NONET, "lsrefs": NONET, "protocol": NONET, "url": NONET, "clone": NONET,
    "sendemail": "no mail", "imap": "no mail", "smtp": "no mail", "send-email": "no mail", "mailmap": "no log", "mailinfo": "no mail", "format": "no format-patch",
    "pretty": "no log", "log": "no log command", "notes": "no notes", "tag": "no tag", "versionsort": "no tag listing", "branch": "no branch command",
    "checkout": "no checkout", "commit": "no commit command", "gpg": "no signing", "user": "no identity", "author": "no identity", "committer": "no identity",
    "web": "no web", "browser": "no browser", "gitweb": "no web", "instaweb": "no web", "gui": "no gui", "guitool": "no gui", "man": "no help", "help": "no help",
    "cvsimport": "no import", "svn": "no import", "p4": "no import", "fastimport": "no import", "filter-branch": "no rewrite", "bundle": "no bundle",
    "grep": "no grep", "blame": "no blame", "bisect": "no bisect", "fsck": "no fsck", "trailer": "no trailers", "column": "no column output",
    "add": "no add command", "init": "no init", "interactive": "no interactive mode", "tar": "no archive", "zip": "no archive", "completion": "no completion",
    "advice": "stderr messages only", "alias": "aliases never shadow plumbing", "apply": "no apply", "worktree": "no worktree command", "pager": "output is captured",
    "reftable": "no ref storage choice", "status": "no status command",
}

def git(env, repo, *a, inp=None):
    return subprocess.run(["git", "-C", repo] + list(a), env=env, capture_output=True, input=inp, check=True).stdout

def build(dst, env):
    git(env, dst, "init", "-q")
    def w(n, t):
        p = os.path.join(dst, n); os.makedirs(os.path.dirname(p) or dst, exist_ok=True)
        if isinstance(t, bytes): open(p, "wb").write(t)
        else: open(p, "w", newline="").write(t)
    lines = ["line %02d\n" % i for i in range(1, 41)]
    w("big.txt", "".join(lines)); w("moved.txt", "".join("move %d\n" % i for i in range(8)))
    w("ws.txt", "a\n\nb\n\nc\n"); w("crlf.txt", "one\r\ntwo\r\n"); w("bin.dat", b"\x00\x01\x02\x03" * 10)
    w("run.sh", "#!/bin/sh\necho x\n"); w("same.py", "def helper():\n    return 'a body long enough to look like a rename'\n\nprint(helper())\n")
    os.symlink("big.txt", os.path.join(dst, "ln")); w("keep/u.py", "k = 1\n")
    def commit():
        git(env, dst, "add", "-A"); t = git(env, dst, "write-tree").decode().strip()
        c = git(env, dst, "commit-tree", t, inp=b"base\n").decode().strip(); git(env, dst, "update-ref", "HEAD", c); return c
    base = commit()
    l2 = list(lines); l2[2] = "line 03 EDITED\n"; l2[9] = "line 10 EDITED\n"; l2[30] = "line 31 EDITED\n"; l2.insert(20, "inserted\n"); w("big.txt", "".join(l2))
    w("moved.txt", "".join("move %d\n" % i for i in (4, 5, 6, 7, 0, 1, 2, 3)))
    w("ws.txt", "a\n\nb  \n\nc\n\n"); w("crlf.txt", "one\r\nTWO\r\n"); w("bin.dat", b"\x00\x09\x02\x03" * 10)
    os.chmod(os.path.join(dst, "run.sh"), 0o755); os.remove(os.path.join(dst, "same.py"))
    w("copy.py", "def helper():\n    return 'a body long enough to look like a rename'\n\nprint(helper())\n")
    w("café.py", "z = 1\n"); os.remove(os.path.join(dst, "ln")); os.symlink("ws.txt", os.path.join(dst, "ln"))
    w("key.txt", "-----BEGIN PRIVATE KEY-----\nBODY\n-----END PRIVATE KEY-----\n")
    return base

def keys_from_git():
    out = subprocess.run(["git", "help", "-c"], capture_output=True, text=True, check=True, env={**os.environ, "GIT_PAGER": "cat", "PAGER": "cat"}).stdout
    ks = set()
    for k in out.split():
        k = re.sub(r"<[^>]*>", "zz", k)
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9.*_-]+)+", k):
            ks.add(k)
    return sorted(ks)

VALUES = ["true", "false", "0", "99", "X!odd value", "always", "never", "patience", "/dev/null"]

def main():
    selfcheck = "--self-check" in sys.argv
    snap = os.path.abspath(sys.argv[1])
    tmp = tempfile.mkdtemp(prefix="cfgkeys.")
    try:
        if selfcheck:
            src = open(snap).read()
            cut = src.replace("-c diff.context=3 ", "").replace(" -U3", "")
            assert cut != src, "self-check cannot find the diff.context pin to remove"
            snap = os.path.join(tmp, "unpinned.sh"); open(snap, "w").write(cut); os.chmod(snap, 0o755)
        env0 = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env0.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t", HOME=tmp)
        repo = os.path.join(tmp, "repo"); os.makedirs(repo)
        base = build(repo, env0)
        def run(extra):
            e = dict(env0); e.update(extra)
            return subprocess.run(["bash", snap, base], cwd=repo, env=e, capture_output=True)
        b = run({})
        if b.returncode != 0 or not b.stdout:
            print("baseline snapshot failed: rc=%d %s" % (b.returncode, b.stderr.decode()[:300])); return 3
        ver = subprocess.run(["git", "--version"], capture_output=True, text=True).stdout.strip()
        allk = keys_from_git()
        if len(allk) < 300:
            print("git help -c listed only %d keys: the enumeration is not working" % len(allk)); return 3
        test = [k for k in allk if k.split(".")[0] not in DENY]
        skipped = sorted({k.split(".")[0] for k in allk} & set(DENY))
        # WHY the key goes into the repository's own .git/config (cc11 r64): the script now clears GIT_CONFIG_COUNT/KEY/VALUE and pins the global and system files to /dev/null on purpose, so those
        # channels can no longer reach it and a test that used them would pass vacuously. A repository's local config is the one channel that still does. Each key and value gets its OWN fresh copy of the
        # repo: a bad value for some keys (core.bare, core.repositoryformatversion) makes git refuse to read the repo at all, so even `git config --unset` fails and a shared copy would stay
        # poisoned for every later key (the first run of this design lost diff.context that way).
        def one(k):
            bad = []
            for v in VALUES:
                wr = os.path.join(tempfile.mkdtemp(prefix="k", dir=tmp), "repo"); shutil.copytree(repo, wr, symlinks=True)
                if subprocess.run(["git", "-C", wr, "config", "--local", k, v], env=env0, capture_output=True).returncode != 0:
                    shutil.rmtree(os.path.dirname(wr), ignore_errors=True)
                    continue  # git refuses this key or value outright, so no run can be affected by it
                r = subprocess.run(["bash", snap, base], cwd=wr, env=env0, capture_output=True)
                shutil.rmtree(os.path.dirname(wr), ignore_errors=True)
                if r.returncode == 0 and r.stdout == b.stdout: continue
                if r.returncode != 0 and not r.stdout: continue
                bad.append((k, v, r.returncode))
            return bad
        with ThreadPoolExecutor(8) as ex:
            flagged = [x for res in ex.map(one, test) for x in res]
        print("%s: %d keys listed, %d exercised x %d values, %d sections skipped" % (ver, len(allk), len(test), len(VALUES), len(skipped)))
        for k, v, rc in flagged[:20]:
            print("FLAGGED %s=%r changes the snapshot bytes (rc=%d): pin it in scripts/review-snapshot.sh" % (k, v, rc))
        if selfcheck:
            hit = any(k == "diff.context" for k, _, _ in flagged)
            print("self-check: %s" % ("diff.context flagged as expected" if hit else "diff.context NOT flagged, the enumeration is blind"))
            return 0 if hit else 1
        return 1 if flagged else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

sys.exit(main())
