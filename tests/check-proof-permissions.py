# Usage: check-proof-permissions.py <review-loop-proof.sh> [hook-file]   (hook-file defaults to proof-confine-hook.py next to the script)
# Exit 0 only when the proof's headless `claude -p` call can rewrite an existing plan file under .claude/ AND is confined while doing so.
# WHY (cc11): claude 2.1.323 -p denies Edit, Write and a Bash redirect on an existing .claude/ file in acceptEdits whatever allow rules are given, so the real scenario
# runs with prompts off (bypassPermissions). That is only acceptable with the deny-by-default PreToolUse hook (tests/proof-confine-hook.py) wired in, a start-up probe
# that must see the hook deny an out-of-bounds call, and a fresh out dir. Each missing piece has its own REJECT line so a test can assert the exact cause.
import os, re, sys
src = open(sys.argv[1]).read()
def reject(why):
    print("REJECT: " + why, file=sys.stderr); sys.exit(1)
calls = re.findall(r"^claude -p .*?(?=\n[^\n]*&& claude_rc=0)", src, re.M | re.S)
if len(calls) != 1 or '"${perm[@]}"' not in calls[0] or "--permission-mode" in calls[0]:
    reject("expected exactly one headless claude -p call that takes its permission flags only from the perm array")
m = re.search(r'if \[\[ \$scenario == real \]\]; then\n(.*?)\nelse\n(.*?)\nfi\n(?=claude -p)', src, re.S)
if not m:
    reject("the permission flags are not split into a real branch and an other-scenarios branch")
real_b, other_b = m.group(1), m.group(2)
if "--permission-mode bypassPermissions" in other_b:
    reject("bypassPermissions must be limited to the real scenario")
pm = re.search(r"--permission-mode (\S+)", real_b)
if not pm or pm.group(1) != "bypassPermissions":
    reject("the proof session runs with permission mode %s, which denies edits to an existing .claude/plan file" % (pm.group(1) if pm else "default"))
if "proof-confine-hook.py" not in real_b or '--settings "$out/proof-settings.json"' not in real_b or '"PreToolUse"' not in real_b or '"matcher": ".*"' not in real_b:
    reject("bypassPermissions without the confinement hook wired through --settings as a PreToolUse hook on every tool")
if '[[ ! -f "$hook" || ! -x "$hook" ]]' not in real_b:
    reject("no start-up refusal when the confinement hook is missing or not executable")
if not re.search(r'!= deny \|\| .*!= allow \]\].*exit 2', real_b):
    reject("no start-up probe that requires the hook to deny an out-of-bounds call")
# WHY the sandbox is checked on the script text (cc11 r37): the OS sandbox is the primary boundary, the hook only the second layer. Each missing piece has its own REJECT line.
if '"enabled": True' not in real_b or '"failIfUnavailable": True' not in real_b:
    reject("the real branch does not enable the OS sandbox with failIfUnavailable (it could silently run unsandboxed)")
if '"allowUnsandboxedCommands": False' not in real_b:
    reject("the OS sandbox allows the unsandboxed retry (dangerouslyDisableSandbox)")
if '"allowWrite": [sys.argv[3]]' not in real_b or not re.search(r'sbx_settings "\$out/proof-settings.json" "\$hook" "\$repo"', real_b):
    reject("the OS sandbox write allowlist is not exactly the scratch repo")
if '"excludedCommands": [sys.argv[4] + " *", os.path.expanduser(sys.argv[4]) + " *", "codex --version"]' not in real_b or "wrapper='~/.claude/config/scripts/codex-call.sh'" not in real_b:
    reject("the OS sandbox excludes more than the one wrapper (codex-call.sh)")
if not re.search(r'-e "\$canary" \]\].*not permitted.*exit 2', real_b, re.S) or 'sbx_settings "$out/sbx-probe-settings.json" ""' not in real_b:
    reject("no start-up probe that requires the sandbox itself to refuse a write outside the scratch repo (hook-free probe run)")
for needle in ("GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_COUNT=4", "GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false", "GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null",
               "GIT_CONFIG_KEY_2=core.pager GIT_CONFIG_VALUE_2=cat", "GIT_CONFIG_KEY_3=diff.external GIT_CONFIG_VALUE_3=", "--record-baseline", 'export PROOF_GIT_BASELINE="$out/git-baseline"'):
    if needle not in real_b:
        reject("the real branch does not pin the git configuration from outside and record the git baseline (missing: %s)" % needle)
if '"$(cat "$pd/sbx-git.txt" 2>/dev/null)" != false' not in real_b:
    reject("no start-up probe that the pinned git configuration reaches the agent's shell")
if "-e \"$4\"" not in src or "exit 2" not in src[src.index('-e "$4"'):src.index('-e "$4"') + 220]:
    reject("the real scenario does not insist on creating its own fresh out dir")
if "the confinement hook ran" not in src:
    reject("no check that the hook logged at least one decision")
hook = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "proof-confine-hook.py")
try:
    h = open(hook).read()
except OSError:
    reject("the confinement hook file is missing: " + hook)
# WHY these markers (cc11 r36): the two guard classes the review found missing, expansion in any quoting but single quotes and the wrapper's own option grammar.
for marker, what in (("def check_wrapper(", "the wrapper option-grammar check"), ("def git_state(", "the git-state baseline check"), ("expansion inside double quotes", "the denial of expansion inside double quotes"),
                     ("expansion in a double-quoted redirect target", "the denial of expansion in a quoted redirect target"), ('must be read-only', "the read-only sandbox requirement")):
    if marker not in h:
        reject("the confinement hook lacks " + what)
# WHY (cc11 r39 CRITICAL): the PATH shim runs outside the OS sandbox (the wrapper that calls it is sandbox-excluded), so it must be a pure logger: no import, source or interpretation of anything under the
# agent-writable repo. check-impl.py imports app.py, so the shim must not reference it, and the behavioral checkers must run generated code only through the sandboxed runner sbx.py.
tdir = os.path.dirname(os.path.abspath(sys.argv[1]))
shim = sys.argv[3] if len(sys.argv) > 3 else os.path.join(tdir, "shim", "codex")
try:
    sh = open(shim).read()
except OSError:
    reject("the real-mode shim file is missing: " + shim)
code_lines = [l for l in sh.split("\n") if not l.lstrip().startswith("#")]
for bad in ("check-impl", "check-tests", "check-modules", "check-behavior", "exec_module", "importlib", "runpy"):
    if any(bad in l for l in code_lines):
        reject("the real-mode shim runs or imports generated code outside the OS sandbox (references %s)" % bad)
for f in ("check-impl.py", "check-tests.py", "check-modules.py"):
    try:
        t = open(os.path.join(tdir, f)).read()
    except OSError:
        reject("missing behavioral checker: " + f)
    if "import sbx" not in t or "sbx.run(" not in t or "subprocess.run(" in t.replace("except (subprocess", ""):
        reject(f + " does not run generated code through the sandboxed runner sbx.run")
# WHY (cc11 r40 CRITICAL): the interpreter's own search path. The sandbox-excluded chain starts python, bash and git in the scratch repo, so the proof must scrub loader variables and check PATH,
# run the hook isolated, and the hook must refuse writes of interpreter-loadable names.
if "PYTHON*|BASH_ENV|ENV|CDPATH|NODE_OPTIONS|NODE_PATH" not in real_b or "is relative or agent-writable" not in real_b:
    reject("the real branch does not scrub the interpreter and loader environment and check PATH before the agent starts")
if '"python3 -I " + sys.argv[2]' not in src:
    reject("the confinement hook is not started with isolated python (python3 -I)")
if "PYLOAD" not in h or "interpreter-loadable" not in h and "planted json.py" not in h:
    reject("the confinement hook does not refuse writes of interpreter-loadable names (json.py, sitecustomize.py, .pth, .so)")
