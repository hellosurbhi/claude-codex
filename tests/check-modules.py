# Usage: check-modules.py <repo>. Exit 0 when the four requested modules behave as asked:
# mathops.add/sub, strops.shout, listops.first, pkginfo.VERSION and describe(), and each module's
# own doctests pass and exist. Behavioral on purpose, so stubs and comment-only markers fail.
# WHY a subprocess: the files are model-written code and must not run inside the harness.
import subprocess, sys, os
repo = sys.argv[1]
code = r'''
import importlib.util as u, sys, doctest, os
def load(n):
    s = u.spec_from_file_location(n, os.path.join(sys.argv[1], n + ".py")); m = u.module_from_spec(s); s.loader.exec_module(m); return m
mo, so, lo, pk = load("mathops"), load("strops"), load("listops"), load("pkginfo")
assert mo.add(2, 3) == 5 and mo.sub(9, 4) == 5
assert so.shout("hi").startswith("HI")
assert lo.first([7, 8]) == 7
assert isinstance(pk.VERSION, str) and pk.VERSION
assert pk.describe() is not None
for m in (mo, so, lo, pk):
    r = doctest.testmod(m)
    assert r.attempted > 0 and r.failed == 0, (m.__name__, r)
'''
try:
    sys.exit(subprocess.run([sys.executable, "-I", "-c", code, repo], timeout=30, capture_output=True).returncode)
except (subprocess.TimeoutExpired, OSError):
    sys.exit(1)
