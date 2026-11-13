# Usage: state-hash.py <dir>. Prints a 16-hex digest of the reviewed file set: every path, whether it exists and its bytes.
# WHY paths and sizes in the digest: a bare concatenation of file contents is unchanged when text moves between files
# (add() from app.py into test_app.py), so a CLEAN verdict would still look current after the change (r28).
import glob, hashlib, os, sys
d = sys.argv[1]
names = set(glob.glob(os.path.join(d, ".claude/plan/*.md")))
# WHY every .py file, helpers included (r31): deleting an imported helper after a CLEAN review must change the digest.
for dp, dn, fn in os.walk(d):
    dn[:] = [x for x in dn if x not in (".git", ".claude", "__pycache__", ".pytest_cache", "node_modules")]
    names |= {os.path.join(dp, f) for f in fn if f.endswith(".py")}
names = sorted(names)
h = hashlib.sha256()
for p in names:
    b = open(p, "rb").read()
    h.update(os.path.relpath(p, d).encode() + b"\0" + str(len(b)).encode() + b"\0" + b + b"\0")
print(h.hexdigest()[:16])
