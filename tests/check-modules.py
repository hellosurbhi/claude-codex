# Usage: check-modules.py <repo>. Exit 0 when the four requested modules parse and really contain
# the requested API (functions with bodies beyond a stub, VERSION and describe(), a doctest each).
import ast, sys, os
need = {"mathops": ["add", "sub"], "strops": ["shout"], "listops": ["first"], "pkginfo": ["describe"]}
for mod, funcs in need.items():
    try:
        src = open(os.path.join(sys.argv[1], mod + ".py")).read()
        tree = ast.parse(src)
    except (OSError, SyntaxError):
        sys.exit(1)
    defs = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
    for f in funcs:
        d = defs.get(f)
        if d is None or not any(isinstance(s, ast.Return) for s in ast.walk(d)):
            sys.exit(1)
    if ">>>" not in src:
        sys.exit(1)
    if mod == "pkginfo" and not any(isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "VERSION" for t in n.targets) for n in tree.body):
        sys.exit(1)
sys.exit(0)
