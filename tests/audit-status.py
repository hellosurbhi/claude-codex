# Usage: audit-status.py <report-file> [--expect APPROVED|UNREVIEWED]
# Exit 0 when the report's LAST non-blank line is exactly one `AUDIT-STATUS: <APPROVED|UNREVIEWED> reviewer=<name>` line,
# no other line starts with `AUDIT-STATUS:`, and (with --expect) the status equals the expected one. Prints the status.
# WHY a structured line, not prose matching: the skills now emit one machine-readable status, so the proof asserts on
# that line only; guessing meaning from free text kept misfiring (r20).
import re, sys
args = sys.argv[1:]
lines = [l.rstrip() for l in open(args[0], encoding="utf-8", errors="replace").read().splitlines()]
nonblank = [l.strip() for l in lines if l.strip()]
status = [l for l in nonblank if l.startswith("AUDIT-STATUS:")]
if len(status) != 1 or nonblank[-1] != status[0]:
    sys.exit(1)
m = re.fullmatch(r"AUDIT-STATUS: (APPROVED|UNREVIEWED) reviewer=(\S.*)", status[0])
if not m:
    sys.exit(1)
if "--expect" in args and m.group(1) != args[args.index("--expect") + 1]:
    sys.exit(1)
print(m.group(1))
