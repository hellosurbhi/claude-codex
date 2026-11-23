# Runs scripts/redact-diff.sh for a test and refuses a dead or short answer.
# WHY (r50, r51): the tests zipped the redactor's stdout against their expectations. A redactor that failed with empty stdout left one empty line, zip stopped there and every check passed
# on nothing. A run must exit 0 and return exactly one output line per input line before any content is compared; otherwise the test exits 1 with the reason.
import subprocess, sys

def run(red, lines, args=(), binary=False):
    r = subprocess.run([red] + list(args), input="\n".join(lines) + "\n", capture_output=True, text=True)
    n = r.stdout.count("\n")
    if r.returncode != 0 or n != len(lines):
        print("REDACTOR FAILED: exit %d, %d output lines for %d input lines" % (r.returncode, n, len(lines)), file=sys.stderr)
        sys.exit(1)
    return r.stdout.split("\n")
