# Shared decoder for the paths git prints in diff headers (evlog.py and check-reviewer-after-limit.py both import it).
# WHY one helper (r50, r51): the snapshot pins core.quotePath=true, so a name with non-ASCII bytes, a tab, a quote or a backslash is written as a double-quoted C string with octal escapes
# ("caf\303\251.py"). Each reader that matched only the unquoted form rejected or misclassified a valid review of such a file, one reader per review round. Parsing headers anywhere else in
# tests/ must go through here; what breaks if a reader re-implements it: that one reader silently disagrees with the filesystem name again.
import re

QSTR = r'"(?:[^"\\]|\\.)*"'
_SIMPLE = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}

def unquote(tok):
    # a git C-quoted string to the filesystem name (str with surrogateescape for non-UTF-8 bytes); an unquoted token is returned unchanged.
    if not (len(tok) >= 2 and tok[0] == '"' and tok[-1] == '"'):
        return tok
    raw, out, i = tok[1:-1], bytearray(), 0
    while i < len(raw):
        c = raw[i]
        if c != "\\":
            out += c.encode("utf-8", "surrogateescape"); i += 1
        elif raw[i + 1:i + 2] in _SIMPLE:
            out.append(_SIMPLE[raw[i + 1]]); i += 2
        elif re.fullmatch(r"[0-3][0-7]{2}", raw[i + 1:i + 4]):
            out.append(int(raw[i + 1:i + 4], 8)); i += 4
        else:
            out += c.encode(); i += 1
    return out.decode("utf-8", "surrogateescape")

def hdr_path(rest):
    # path of a "--- " or "+++ " header (the text after the marker): decode quoting, drop a trailing tab and git's a/ or b/ prefix.
    m = re.match(QSTR, rest)
    return unquote(m.group(0) if m else rest.split("\t")[0])[2:]

def _hdr_candidates(body):
    # every (a_path, b_path) reading of the text after "diff --git "; an unquoted name may itself contain " b/", so a header can have several.
    cands = []
    m = re.match(QSTR, body)
    lefts = [(m.group(0), body[m.end():])] if m else [(body[:i], body[i:]) for i in range(len(body)) if body.startswith(" b/", i)]
    for left, tail in lefts:
        if not tail.startswith(" "):
            continue
        right = tail[1:]
        if right.startswith('"') and not re.fullmatch(QSTR, right):
            continue
        a_, b_ = unquote(left), unquote(right)
        if a_.startswith("a/") and b_.startswith("b/"):
            cands.append((a_[2:], b_[2:]))
    return cands

def _section_paths(rest):
    # (a, b) read from the section's own header lines (rename/copy from and to, then --- and +++), None for a side they do not name. WHY these first: a "diff --git a/x b/y.py b/x b/y.py" line cannot be split
    # reliably when a name contains " b/", but the --- and +++ lines carry one unambiguous name each (git ends an unquoted name that has a space with a tab, which hdr_path strips).
    a_ = b_ = None
    for l in rest:
        if l.startswith("diff --git ") or l.startswith("@@"):
            break
        for key, side in (("rename from ", 0), ("copy from ", 0), ("rename to ", 1), ("copy to ", 1)):
            if l.startswith(key):
                v = unquote(l[len(key):])
                if side == 0: a_ = v
                else: b_ = v
        if l.startswith("--- ") and a_ is None and not l[4:].startswith("/dev/null"):
            a_ = hdr_path(l[4:])
        elif l.startswith("+++ ") and b_ is None and not l[4:].startswith("/dev/null"):
            b_ = hdr_path(l[4:])
    return a_, b_

def diff_git_paths(line, rest=()):
    # (a_path, b_path) without the a/ b/ prefixes from a "diff --git" line, quoted or not; None when the line is not one. Pass the lines that follow it in the same section (rest) to name a path that
    # contains " b/" exactly; without them, a header whose two halves are equal is resolved first, then the first generic split.
    if not line.startswith("diff --git "):
        return None
    cands = _hdr_candidates(line[len("diff --git "):])
    if not cands:
        return None
    sa, sb = _section_paths(rest)
    if sa is not None or sb is not None:
        # a new or deleted file names only one side in --- and +++; its header has the same path on both.
        a_, b_ = sa if sa is not None else sb, sb if sb is not None else sa
        return a_, b_
    for pair in cands:
        if pair[0] == pair[1]:
            return pair
    return cands[0]
