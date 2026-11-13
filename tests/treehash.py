# Usage: treehash.py <repo>. Prints one sha256 over every .py file under the repo (relative path and exact bytes,
# sorted), skipping .git, .claude and caches. It pins "the code state" exactly: paths, contents, deletions and
# indentation all change the digest, which the review-binding check needs (r15).
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
for d, dirs, files in os.walk(root):
    dirs[:] = sorted(x for x in dirs if x not in (".git", ".claude", "__pycache__", ".pytest_cache", "node_modules"))
    for f in sorted(files):
        if f.endswith(".py"):
            p = os.path.join(d, f)
            h.update(os.path.relpath(p, root).encode() + b"\0" + open(p, "rb").read() + b"\0")
print(h.hexdigest())
