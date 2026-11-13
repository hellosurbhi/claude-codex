# Usage: check-impl.py <app.py>. Exit 0 when importing the file gives a module-level add that
# really adds (behavioral, so stubs, comments, annotations and signature style cannot fool it).
# WHY a subprocess: the file is model-written code and must not run inside the harness itself.
import subprocess, sys
code = (
    "import importlib.util as u, sys\n"
    "s = u.spec_from_file_location('app_under_test', sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)\n"
    "assert m.add(2, 3) == 5 and m.add(-4, 4) == 0 and m.add(10, 7) == 17\n"
)
try:
    sys.exit(subprocess.run([sys.executable, "-I", "-c", code, sys.argv[1]], timeout=10, capture_output=True).returncode)
except (subprocess.TimeoutExpired, OSError):
    sys.exit(1)
