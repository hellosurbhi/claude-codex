# Usage: check-limit-hit.py <events.jsonl>. Exit 0 when a real codex-call.sh execution (not quoted
# documentation) got the usage-limit reply.
import json, sys
from evlib import first_limit_cmd_index
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
sys.exit(0 if first_limit_cmd_index(ev) is not None else 1)
