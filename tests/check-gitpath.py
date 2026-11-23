# check-gitpath.py: diff_git_paths must name the exact paths for headers the greedy split got wrong (r52 finding 2). Exit 0 when every case holds, else print the first mismatch and exit 1.
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gitpath import diff_git_paths

cases = [
    ("a path that contains ' b/' with no section lines", "diff --git a/x b/y.py b/x b/y.py", (), ("x b/y.py", "x b/y.py")),
    ("the same path read from the --- and +++ lines", "diff --git a/x b/y.py b/x b/y.py", ("index 1..2 100644", "--- a/x b/y.py\t", "+++ b/x b/y.py\t", "@@ -1 +1 @@"), ("x b/y.py", "x b/y.py")),
    ("a rename whose names contain spaces", "diff --git a/old name.py b/new name.py", ("similarity index 100%", "rename from old name.py", "rename to new name.py"), ("old name.py", "new name.py")),
    ("a rename to a name that contains ' b/'", "diff --git a/p b/q.py b/r b/s.py", ("similarity index 90%", "rename from p b/q.py", "rename to r b/s.py", "--- a/p b/q.py\t", "+++ b/r b/s.py\t"), ("p b/q.py", "r b/s.py")),
    ("a path with spaces", "diff --git a/my mod.py b/my mod.py", (), ("my mod.py", "my mod.py")),
    ("a new file", "diff --git a/n.py b/n.py", ("new file mode 100644", "--- /dev/null", "+++ b/n.py"), ("n.py", "n.py")),
    ("a quoted non-ASCII name", 'diff --git "a/caf\\303\\251.py" "b/caf\\303\\251.py"', (), ("café.py", "café.py")),
    ("not a diff header", "index 1..2 100644", (), None),
]
for name, line, rest, want in cases:
    got = diff_git_paths(line, rest)
    if got != want:
        print("%s: got %r, wanted %r" % (name, got, want)); sys.exit(1)
