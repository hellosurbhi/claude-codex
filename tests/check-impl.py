# Usage: check-impl.py <app.py>. Exit 0 when importing the file gives a module-level add that
# really adds (behavioral, so stubs, comments, annotations and signature style cannot fool it).
# WHY a subprocess: the file is model-written code and must not run inside the harness itself.
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sbx
code = (
    "import importlib.util as u, sys\n"
    "s = u.spec_from_file_location('app_under_test', sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)\n"
    "assert m.add(2, 3) == 5 and m.add(-4, 4) == 0 and m.add(10, 7) == 17\n"
    "print('CHECKS-DONE')\n"
)
try:
    # WHY the sentinel (CodeRabbit r42): exit 0 alone is not proof the asserts ran, since module code may call os._exit(0) or sys.exit(0) on import.
    r = sbx.run([sys.executable, "-I", "-c", code, sys.argv[1]], timeout=10)
    if not (r.returncode == 0 and r.stdout.rstrip().endswith(b"CHECKS-DONE")):
        print("REJECT: add() failed its checks (exit %d, sentinel %s)" % (r.returncode, "present" if b"CHECKS-DONE" in r.stdout else "missing"), file=sys.stderr); sys.exit(1)
    sys.exit(0)
except (subprocess.TimeoutExpired, OSError) as exc:
    print("REJECT: the add() check could not run: %s" % type(exc).__name__, file=sys.stderr); sys.exit(1)
