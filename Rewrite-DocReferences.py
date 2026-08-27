#!/usr/bin/env python3
"""
Rewrite assistant-tool doc references out of the AngelScript sources that ship.

Two different things are being fixed, because the two sets of documents are
handled differently:

  * Docs that live *inside* a shipping script root were renamed to
    ARCHITECTURE.md, so references to them are repointed and stay exact.
  * Docs under Plugins/CkFoundation/Source/<Module>/ never ship and are shared
    with other projects, so renaming 112 of them is disproportionate. References
    to those name the module instead of the file, which stays accurate whatever
    the file is called.

Run from the repository root:
    python CkAuto/Rewrite-DocReferences.py --check
    python CkAuto/Rewrite-DocReferences.py --apply
"""

import argparse
import os
import re
import sys

ROOTS = [
    "Script",
    "Plugins/CkFoundation/Script",
    "Plugins/CkTests/Script",
]

# Docs renamed in place; keep the citation precise.
RENAMED = [
    (re.compile(r"Script/Inputs/CLAUDE\.md", re.I), "Script/Inputs/ARCHITECTURE.md"),
    (re.compile(r"Script/Inventory/CLAUDE\.md", re.I), "Script/Inventory/ARCHITECTURE.md"),
    (re.compile(r"Script/CLAUDE\.md", re.I), "Script/ARCHITECTURE.md"),
]

# "CkGoap/CLAUDE.md" -> "the CkGoap docs", without producing "the the".
MODULE_DOC = re.compile(r"(the\s+)?([A-Za-z0-9_]+)[/ ]CLAUDE\.md", re.I)

# Any leftover bare mention.
BARE = re.compile(r"(the\s+)?CLAUDE\.md", re.I)


def rewrite(text):
    for pat, dst in RENAMED:
        text = pat.sub(dst, text)

    def _module(m):
        lead, mod = m.group(1), m.group(2)
        if mod.upper() == "ARCHITECTURE":
            return m.group(0)
        return "the %s docs" % mod

    text = MODULE_DOC.sub(_module, text)
    text = BARE.sub("the module docs", text)
    return text


def iter_files():
    for root in ROOTS:
        for dirpath, _, filenames in os.walk(root):
            for f in sorted(filenames):
                if f.endswith(".as") or f.endswith(".py"):
                    yield os.path.join(dirpath, f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if not args.apply and not args.check:
        ap.error("pass --check or --apply")

    hits = 0
    changed = 0
    for path in iter_files():
        raw = open(path, "rb").read()
        text = raw.decode("utf-8", errors="replace")
        if "claude" not in text.lower():
            continue
        new = rewrite(text)
        if new == text:
            # Mention that survived rewriting; surface it rather than hide it.
            for num, line in enumerate(text.splitlines(), 1):
                if "claude" in line.lower():
                    print("  UNHANDLED %s:%d  %s" % (path, num, line.strip()[:95]))
                    hits += 1
            continue
        changed += 1
        if args.apply:
            open(path, "wb").write(new.encode("utf-8"))

    print("files %s: %d" % ("rewritten" if args.apply else "needing rewrite", changed))
    if hits:
        print("unhandled mentions: %d" % hits)
    return 1 if (changed or hits) and args.check else 0


if __name__ == "__main__":
    sys.exit(main())
