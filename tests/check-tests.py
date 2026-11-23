# Usage: check-tests.py <repo>. Exit 0 when the TDD run left the requested test file (test_app.py), its unittest run succeeds with at least one test, and it calls add().
# WHY no -I: it drops the work dir from sys.path and `from app import add` would fail. WHY a subprocess run (model-written code must not run inside the harness) with a result parse: exit 0 alone also happens when no test ran, so "Ran N tests" with N >= 1 and a final OK are required.
# WHY the AST call check: a test that passes without ever calling add() proves nothing about the requested function; a call to a name or attribute called add is the cheap detectable signal (it cannot prove the assertion is meaningful).
import ast, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sbx
repo = sys.argv[1]; tf = os.path.join(repo, "test_app.py")
def rej(m): print("REJECT: " + m, file=sys.stderr); sys.exit(1)
if not os.path.isfile(tf): rej("test_app.py is missing from the work dir")
try: tree = ast.parse(open(tf).read())
except (SyntaxError, ValueError): rej("the requested tests did not pass (test_app.py does not parse)")
try:
    r = sbx.run([sys.executable, "-B", "-m", "unittest", "-v", "test_app"], cwd=repo, timeout=60)
    r.stdout, r.stderr = r.stdout.decode(errors="replace"), r.stderr.decode(errors="replace")
except (subprocess.TimeoutExpired, OSError) as exc: rej("the requested tests did not pass (could not run: %s)" % type(exc).__name__)
m = re.search(r"^Ran (\d+) tests? ", r.stderr, re.M)
if r.returncode != 0 or not m or int(m.group(1)) < 1 or not re.search(r"^OK\b", r.stderr, re.M):
    rej("the requested tests did not pass (exit %d, %s)" % (r.returncode, "ran %s tests" % m.group(1) if m else "no test run reported"))
if not any(isinstance(n, ast.Call) and ((isinstance(n.func, ast.Name) and n.func.id == "add") or (isinstance(n.func, ast.Attribute) and n.func.attr == "add")) for n in ast.walk(tree)):
    rej("test_app.py never calls add()")
