# Usage: check-hook-differential.py <proof-confine-hook.py>   Exit 0 only when, for every generated command line the hook ALLOWS, real bash executes exactly the commands the hook validated.
# WHY (cc11 r58 HIGH): the hook's lexer is a second parser of bash. Where the two disagree on where a construct ends (a tab-indented heredoc terminator, a `#` comment hiding a heredoc
# operator, `>&2x`, a glob bracket in a path, an empty command around `;;`) the hook skipped text bash runs, or validated text bash never runs. This test generates command lines from
# fragments covering those constructs, asks the hook (in process) for a decision and, for each allowed line, runs it under real bash in a throwaway directory with every command name
# replaced by a shell function that only logs its argv, so nothing real runs. Security: the set bash executes must be inside the set the hook validated; and when the line has no `||` (so
# nothing short-circuits) the two sets must be equal, otherwise the hook validated something bash never ran, which means the two parsers read the line differently.
import importlib.util, itertools, os, subprocess, sys, tempfile
hookpath = os.path.abspath(sys.argv[1])
base = os.path.realpath(tempfile.mkdtemp(prefix="hookdiff"))
import atexit, shutil; atexit.register(shutil.rmtree, base, True)  # WHY (cc11 r64): the fixture used to outlive every run in the system temp dir; atexit also runs on sys.exit
root = os.path.join(base, "repo"); os.makedirs(root)
for f in ("app.py", "in.txt"):
    open(os.path.join(root, f), "w").write("x\n")
os.mkdir(os.path.join(root, "link")); open(os.path.join(root, "link", "secret"), "w").write("x\n")
subprocess.run(["git", "init", "-q", root], check=True)
gb = os.path.join(base, "gitbase")
subprocess.run([sys.executable, hookpath, "--record-baseline", root, gb], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.environ["PROOF_SCRATCH_ROOT"] = root; os.environ["PROOF_GIT_BASELINE"] = gb
spec = importlib.util.spec_from_file_location("proofhook", hookpath); h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
h.ROOT = os.path.realpath(root)
NAMES = ["echo", "printf", "true", "pwd", ":", "sleep", "mkdir", "cat", "head", "tail", "ls", "wc", "test", "[", "grep", "file", "stat", "git", "codex", "PAYLOAD", "touch", "id"]
# one write per record: pipeline stages run in parallel and would interleave piecemeal writes
STUBS = ("__l() { builtin local r=\"$1\" x; builtin shift; for x in \"$@\"; do r+=$'\\037'\"$x\"; done; builtin printf '%s\\036' \"$r\" >> \"$LOG\"; }\n"
         + "".join("%s() { __l %s \"$@\"; return 0; }\n" % (n, n) for n in NAMES))
ATOMS = ["echo a", "true", "pwd", "cat", "ls", "printf 'x'", "test -f app.py", "head -n 1 app.py", "git status", "PAYLOAD hidden", "echo b c", "grep -c x app.py"]
HD = ["<<'EOF'\nbody\nEOF", "<<'EOF'\n$(not run)\nEOF", "<<-'EOF'\n\tEOF\nPAYLOAD after-tab-eof\nEOF", "<<-'EOF'\nbody\n\tEOF", "<<'EOF'\nEOF", "<<'EOF' \nbody\nEOF", "<<'EOF'\nbody\nEOF ",
      "<<'EOF'\nbody\n EOF\nPAYLOAD after-space-eof\nEOF", "<<'EOF'x\nbody\nEOFx\nPAYLOAD y\nEOF", "<<\"EOF\"\nbody\nEOF", "<<EOF\nbody\nEOF", "<<\\EOF\nbody\nEOF", "<<'EOF' <<'END'\na\nEOF\nb\nEND",
      "<<'EOF' | cat\nbody\nEOF", "<<'EOF' && echo z\nbody\nEOF", "<<'EOF'\nbody\nEOF\nPAYLOAD z", "3<<'EOF'\nbody\nEOF", "<<<'x'", "<<'EOF'\r\nbody\r\nEOF\r\n", "<<'EOF'\nbody\nEOF\r\nPAYLOAD cr\nEOF",
      "<<'E O F'\nbody\nE O F", "<<'EOF'\n\nEOF", "<< 'EOF'\nbody\nEOF", "<<'EOF'\nPAYLOAD inside\nEOF"]
MISC = ["# PAYLOAD commented", "echo a # PAYLOAD commented", "echo a #<<'EOF'\nPAYLOAD after-comment\nEOF", "echo a# b", "#<<'EOF'\nPAYLOAD z\nEOF", "echo a \\\nPAYLOAD continued", "echo a\\\nb",
        "echo a;; PAYLOAD x", "echo a ;;", ";; echo a", "echo a ; ; echo b", "echo a &&", "&& echo a", "echo a || ; echo b", "echo a |", "| cat", "echo a ;", "echo a;\necho b", "\n\necho a\n\n",
        "echo a >out.txt", "echo a >&2", "echo a >&2x", "echo a >&10", "echo a 2>&1", "echo a 12>out.txt", "echo a 5>out.txt", "echo a >&-", "echo a <&0", "echo a >| out.txt", "echo a &> out.txt", "echo a <> out.txt",
        "cat <in.txt", "cat l[i]nk/secret", "cat link/[s]ecret", "cat [a]pp.py", "[ -f app.py ]", "[ -f a[p]p.py ]", "[ app.py = ]", "echo [x]", "echo ]", "echo '['", "echo a>out.txt", "echo a>out.txt;echo b",
        "case x in x) echo a;; esac", "f() { echo a; }; f", "{ echo a; }", "( echo a )", "echo <(echo a)", "echo a & echo b", "echo `id`", "echo $(id)", "echo a\x00b", "echo a\rb", "echo \"a\rb\"", "echo $'a'", "echo ~",
        "echo a\tb", "echo a\x0bb", "echo 'a\nb'", "echo \"a\nb\"", "echo a <<'EOF' >out.txt\nx\nEOF", "! echo a", "time echo a", "echo a\\\n", "echo \\#", "echo a \\# PAYLOAD", "true;true", "true&&true", "true||PAYLOAD x"]
SEPS = [" ; ", " && ", " || ", " | ", "\n", ";", "\n\n", " ;; ", "; ;", " |& "]
cmds = list(MISC)
for hd in HD:
    for a in ("cat", "echo a", "true", "PAYLOAD x"):
        cmds.append("%s %s" % (a, hd)); cmds.append("%s %s\nPAYLOAD tail" % (a, hd)); cmds.append("echo pre ; %s %s\necho post" % (a, hd))
for a, b in itertools.product(ATOMS, ATOMS):
    for sp in SEPS:
        cmds.append(a + sp + b)
for a in ATOMS:
    for t in (" #c", " ;#c", "\n#c\n", " >out.txt", " 2>&1", " 1>out.txt", " >/dev/null", " <in.txt"):
        cmds.append(a + t)
cmds = list(dict.fromkeys(cmds))
bad, allowed, ran = [], 0, 0
env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": base}
for cmd in cmds:
    try:
        h.CWD = root
        h.decide({"tool_name": "Bash", "cwd": root, "tool_input": {"command": cmd}})
        ok = True
    except h.Deny:
        ok = False
    except Exception as e:
        ok = False
    if not ok:
        continue
    allowed += 1
    if "\x00" in cmd:
        bad.append("ALLOWED WITH A NUL BYTE (bash cannot be given one, so the two parsers cannot agree) %r" % cmd)
        continue
    validated = [a for a, _ in h.lex(cmd) if a]
    log = os.path.join(base, "log"); open(log, "w").close()
    p = subprocess.run(["bash", "--noprofile", "--norc", "-c", STUBS + "\n" + cmd], cwd=root, env=dict(env, LOG=log), capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=20)
    ran += 1
    executed = [r.split("\x1f") for r in open(log, errors="replace").read().split("\x1e") if r]
    vs = {tuple((base + w[1:]) if w.startswith("~") and w[1:2] in ("", "/") else w for w in a) for a in validated}  # bash expands an unquoted leading ~ to HOME
    es = {tuple(a) for a in executed}
    # echo -n and friends are logged by name and args exactly as bash passed them, so a quoted word compares equal to the hook's unquoted view
    if not es <= vs:
        bad.append("EXECUTED BUT NOT VALIDATED %r: bash ran %r, hook validated %r" % (cmd, sorted(es - vs), sorted(vs)))
    elif "||" not in cmd and es != vs:
        bad.append("VALIDATED BUT NOT RUN %r: hook validated %r, bash ran %r" % (cmd, sorted(vs - es), sorted(es)))
print("hook differential: %d lines generated, %d allowed and run under bash, %d mismatches" % (len(cmds), allowed, len(bad)))
for b in bad[:60]:
    print("FAIL " + b.replace("\n", "\\n").replace("\r", "\\r"))
sys.exit(1 if bad else 0)
