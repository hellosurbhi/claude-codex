# Usage: state-hash.py <dir>. Prints a 16-hex digest of the reviewed file set: every path, whether it exists and its bytes.
# WHY paths and sizes in the digest: a bare concatenation of file contents is unchanged when text moves between files
# (add() from app.py into test_app.py), so a CLEAN verdict would still look current after the change (r28).
import glob, hashlib, os, sys
d = sys.argv[1]
names = sorted(set(glob.glob(os.path.join(d, "app.py")) + glob.glob(os.path.join(d, "test*.py")) + glob.glob(os.path.join(d, ".claude/plan/*.md"))))
h = hashlib.sha256()
for p in names:
    b = open(p, "rb").read()
    h.update(os.path.relpath(p, d).encode() + b"\0" + str(len(b)).encode() + b"\0" + b + b"\0")
print(h.hexdigest()[:16])
