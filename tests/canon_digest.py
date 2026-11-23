# The one canonical encoding for "a set of named blobs" digests (tests/treehash.py and tests/state-hash.py both load this file by path).
# WHY (cc11 r60 MEDIUM): treehash.py once hashed name NUL bytes NUL, with no lengths, so a file whose bytes contain "\0other.py\0..." produced the same digest as two files, and a changed
# code state could look unchanged. Every field is framed as <decimal length>:<bytes>, so no field's content can pose as a boundary. Loaded by path because callers run python3 -I, which keeps
# the script directory off sys.path. WHAT breaks if this is simplified back to a delimiter: that collision returns (tests/test-checkers.sh r60 holds the pair).
def feed(h, name, data):
    for field in (name, data):
        h.update(str(len(field)).encode() + b":" + field)
