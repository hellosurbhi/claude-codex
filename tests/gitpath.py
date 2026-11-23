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

def diff_git_paths(line):
    # (a_path, b_path) without the a/ b/ prefixes from a "diff --git" line, quoted or not; None when the line is not one.
    m = re.fullmatch(r"diff --git (" + QSTR + r"|a/.+) (" + QSTR + r"|b/.+)", line)
    if not m:
        return None
    a_, b_ = unquote(m.group(1)), unquote(m.group(2))
    if not (a_.startswith("a/") and b_.startswith("b/")):
        return None
    return a_[2:], b_[2:]
