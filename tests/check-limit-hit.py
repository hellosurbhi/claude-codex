# Usage: check-limit-hit.py <wrapper.jsonl>. Exit 0 when a real Codex wrapper execution failed
# with the usage-limit error (quoted documentation never reaches the wrapper).
import sys
import wlog
evs = [e for e in wlog.load(sys.argv[1]) if e["wrapper"] in ("fake", "real")]
sys.exit(0 if wlog.limit_index(evs) is not None else 1)
