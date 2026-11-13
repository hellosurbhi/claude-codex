# Usage: check-impl.py <app.py>. Exit 0 when the file defines add(a, b) whose body returns a + b
# (any parameter names, annotations allowed); comments, stubs and pass-only bodies do not count.
import ast, sys
try:
    tree = ast.parse(open(sys.argv[1]).read())
except (OSError, SyntaxError):
    sys.exit(1)
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef) and n.name == "add" and len(n.args.args) == 2:
        p = [a.arg for a in n.args.args]
        for r in ast.walk(n):
            v = getattr(r, "value", None) if isinstance(r, ast.Return) else None
            if isinstance(v, ast.BinOp) and isinstance(v.op, ast.Add) and isinstance(v.left, ast.Name) and isinstance(v.right, ast.Name) and {v.left.id, v.right.id} == set(p):
                sys.exit(0)
sys.exit(1)
