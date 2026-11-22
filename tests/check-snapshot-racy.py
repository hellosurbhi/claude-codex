# Usage: check-snapshot-racy.py <review-snapshot.sh>. Exit 0 only when a same-second, same-size edit still shows in the snapshot.
# WHY (r29 flake): git re-hashes a file only when its stat differs from the index entry or the entry is "racy" (entry mtime not older than
# the index file). A plain `cp` of the index gave the snapshot's private copy a fresh mtime, so a same-size edit made in the same second as
# the last index write looked unchanged and vanished from the snapshot with exit 0. The fixture below makes that window deterministic:
# it starts each attempt early in a second, does add + edit back to back (discarding an attempt whose second rolled over), then waits for the
# next second before running the snapshot.
import os, subprocess, sys, tempfile, time

snap = os.path.abspath(sys.argv[1])
env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")

def git(repo, *a, inp=None):
    return subprocess.run(["git", "-C", repo] + list(a), env=env, capture_output=True, text=True, input=inp, check=True).stdout

def attempt():
    while time.time() % 1 > 0.25:
        time.sleep(0.01)
    with tempfile.TemporaryDirectory() as repo:
        git(repo, "init", "-q")
        open(os.path.join(repo, "app.py"), "w").write("value = 1111\n")
        open(os.path.join(repo, "other.py"), "w").write("x = 1\n")
        # The base tree is built in a scratch index so the repo's own index is first written by the `add` below (git smudges racy entries only
        # when an older index already exists; a first write leaves them as they are, which is the state a fresh `git commit` also leaves).
        sidx = dict(env, GIT_INDEX_FILE=os.path.join(repo, "..", "scratch-index-%d" % os.getpid()))
        subprocess.run(["git", "-C", repo, "add", "-A"], env=sidx, check=True)
        tree = subprocess.run(["git", "-C", repo, "write-tree"], env=sidx, capture_output=True, text=True, check=True).stdout.strip()
        os.remove(sidx["GIT_INDEX_FILE"])
        base = git(repo, "commit-tree", tree, inp="base\n").strip()
        git(repo, "update-ref", "HEAD", base)
        open(os.path.join(repo, "other.py"), "w").write("x = 2\n")  # makes the snapshot non-empty whatever happens to app.py
        sec = int(time.time())
        git(repo, "add", "-A")  # the index write the racy window is measured against
        open(os.path.join(repo, "app.py"), "w").write("value = 2222\n")  # same size, different bytes
        if int(time.time()) != sec:
            return None
        # The deterministic part: let the clock tick over BEFORE the snapshot runs, so a plain `cp` stamps the copy one second later than the
        # entry, which is exactly the case the flake hit by chance (about 1 run in 40) when the second rolled over during the script.
        while int(time.time()) == sec:
            time.sleep(0.01)
        out = subprocess.run([snap, base], cwd=repo, env=env, capture_output=True, text=True)
        return out.returncode == 0 and "+value = 2222" in out.stdout and "+x = 2" in out.stdout

done = 0
for _ in range(40):
    r = attempt()
    if r is None:
        continue
    if not r:
        print("same-second same-size edit missing from the snapshot")
        sys.exit(1)
    done += 1
    if done == 3:
        break
if done < 3:
    print("could not build 3 same-second attempts")
    sys.exit(2)
