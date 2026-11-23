# Usage: check-modules.py <repo>. Exit 0 when the four requested modules behave as asked:
# mathops.add/sub, strops.shout, listops.first, pkginfo.VERSION and describe(), and each module's
# own doctests pass and exist. Behavioral on purpose, so stubs and comment-only markers fail.
# WHY a subprocess: the files are model-written code and must not run inside the harness.
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sbx
repo = sys.argv[1]
code = r'''
import importlib, sys, doctest
# WHY the repo on sys.path and real imports: doctests and sibling imports must work as under normal execution.
sys.path.insert(0, sys.argv[1])
mo, so, lo, pk = (importlib.import_module(n) for n in ("mathops", "strops", "listops", "pkginfo"))
assert mo.add(2, 3) == 5 and mo.sub(9, 4) == 5
assert so.shout("hi").startswith("HI")
assert lo.first([7, 8]) == 7
assert isinstance(pk.VERSION, str) and pk.VERSION
assert pk.describe() is not None
for m in (mo, so, lo, pk):
    r = doctest.testmod(m)
    assert r.attempted > 0 and r.failed == 0, (m.__name__, r)
print('CHECKS-DONE')
'''
try:
    # WHY the sentinel (CodeRabbit r43): exit 0 alone is not proof the checks ran (a module may exit 0 on import).
    r = sbx.run([sys.executable, "-I", "-c", code, repo], timeout=30)
    if not (r.returncode == 0 and r.stdout.rstrip().endswith(b"CHECKS-DONE")):
        print("REJECT: the four modules failed their checks (exit %d, sentinel %s)" % (r.returncode, "present" if b"CHECKS-DONE" in r.stdout else "missing"), file=sys.stderr); sys.exit(1)
    sys.exit(0)
except (subprocess.TimeoutExpired, OSError) as exc:
    print("REJECT: the module checks could not run: %s" % type(exc).__name__, file=sys.stderr); sys.exit(1)
