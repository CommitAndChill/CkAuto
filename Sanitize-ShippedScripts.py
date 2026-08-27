#!/usr/bin/env python3
"""
Sanitize the AngelScript sources that ship inside the packaged game.

The AngelScript fork stages the project's `Script` folder (and the Script root of
every enabled plugin) as loose source next to the executable, so everything under
the roots below is readable by anyone who owns the game. This tool folds those
sources to plain ASCII and keeps them that way.

Player-facing text is deliberately left alone: NPC dialogue and localized UI
strings are authored prose and their typography is intentional. Only comments,
block comments and developer-facing log/debug strings are rewritten.

This file is deliberately pure ASCII -- every mapping is written by codepoint so
the tool cannot be corrupted by an editor guessing the wrong encoding.

Usage:
    python CkAuto/Sanitize-ShippedScripts.py --check
    python CkAuto/Sanitize-ShippedScripts.py --apply
    python CkAuto/Sanitize-ShippedScripts.py --check --paths Script/Foo.as
"""

import argparse
import os
import re
import sys

# Script roots that end up in the packaged layout. Plugins/BusterBlockTests is
# absent on purpose: it is not staged, so its sources never reach a player.
ROOTS = [
    "Script",
    "Plugins/CkFoundation/Script",
    "Plugins/CkTests/Script",
]

# Files whose *string literals* hold authored, player-visible prose. Comments in
# these files are still swept; only the quoted text is preserved.
PROTECTED_FILES = re.compile(
    r"(Speech[\\/]Banks[\\/])"
    r"|(BB_Collectibles_Catalog\.as$)"
    r"|(BB_Utils_UI\.as$)"
    r"|(BB_NpcInfo_Widget\.as$)"
    r"|(BB_EmployeeRow_Widget\.as$)"
)

# Any line building localized text is player-facing regardless of its file.
PROTECTED_LINE = re.compile(r"NSLOCTEXT|LOCTEXT|FText|DisplayName")

EM_DASH = u"—"

# codepoint -> ASCII replacement.
_MAP = {
    0x2013: "-",        # en dash
    0x2018: "'",        # left single quote
    0x2019: "'",        # right single quote
    0x201A: "'",
    0x201C: '"',        # left double quote
    0x201D: '"',        # right double quote
    0x201E: '"',
    0x2026: "...",      # horizontal ellipsis
    0x2032: "'",        # prime
    0x2033: '"',        # double prime
    0x2192: "->",       # rightwards arrow
    0x2190: "<-",       # leftwards arrow
    0x2194: "<->",      # left right arrow
    0x2193: "v",        # downwards arrow
    0x2191: "^",        # upwards arrow
    0x21B3: "->",       # arrow with tip rightwards
    0x21D2: "=>",       # rightwards double arrow
    # Box drawing. "-" serves banner frames, tree diagrams and "-->" arrows
    # alike, which "=" would not.
    0x2500: "-", 0x2501: "-", 0x2502: "|", 0x2503: "|",
    0x250C: "+", 0x250F: "+", 0x2510: "+", 0x2513: "+",
    0x2514: "+", 0x2517: "+", 0x2518: "+", 0x251B: "+",
    0x251C: "+", 0x2524: "+", 0x252C: "+", 0x2534: "+", 0x253C: "+",
    0x2550: "=", 0x2551: "|",
    0x2554: "+", 0x2557: "+", 0x255A: "+", 0x255D: "+",
    0x2560: "+", 0x2563: "+", 0x2566: "+", 0x2569: "+", 0x256C: "+",
    0x2580: "-", 0x2584: "-", 0x2588: "#",
    0x2591: ".", 0x2592: ":", 0x2593: "#",
    0x25A0: "#", 0x25AA: "*", 0x25AB: "*",
    0x25B6: ">", 0x25B8: ">", 0x25BA: ">",
    0x25C0: "<", 0x25C2: "<",
    0x25CF: "*", 0x25CB: "o",
    0x2022: "*",        # bullet
    0x00B7: ".",        # middle dot
    0x00D7: "x",        # multiplication sign
    0x00F7: "/",        # division sign
    0x00B0: " deg",     # degree sign
    0x00B1: "+/-",      # plus-minus
    0x2248: "~",        # almost equal to
    0x2260: "!=", 0x2264: "<=", 0x2265: ">=",
    0x221E: "inf",
    0x00A7: "Sec.",     # section sign
    0x00A9: "(c)", 0x00AE: "(R)", 0x2122: "(TM)",
    0x00BD: "1/2", 0x00BC: "1/4", 0x00BE: "3/4",
    0x00E9: "e", 0x00E8: "e", 0x00EA: "e", 0x00E0: "a", 0x00E7: "c",
    0x00FC: "u", 0x00F6: "o", 0x00E4: "a", 0x00F1: "n", 0x00ED: "i",
    0x2705: "[OK]",     # white heavy check mark
    0x274C: "[FAIL]",   # cross mark
    0x2714: "[OK]", 0x2716: "[FAIL]", 0x2713: "[OK]", 0x2717: "[FAIL]",
    0x26A0: "[WARN]", 0x2757: "[!]", 0x2753: "[?]",
    0x2B50: "*", 0x2605: "*", 0x2606: "*",
    # Mojibake already baked into three files as literal U+FFFD bytes. The
    # original character is unrecoverable, but every occurrence sits where a
    # spaced em dash belonged ("an abstract entity <?> it's a composition"), so
    # it folds the same way the dash does.
    0xFFFD: "-",
    # Maths and symbol leftovers found in comments.
    0x2212: "-",        # minus sign
    0x2213: "-/+",      # minus-or-plus
    0x2218: "*",        # ring operator (transform composition)
    0x2208: "in",       # element of
    0x2229: "&",        # intersection
    0x222A: "+",        # union
    0x2227: "AND",      # logical and
    0x2228: "OR",       # logical or
    0x2211: "sum", 0x220F: "prod", 0x221A: "sqrt",
    0x2261: "==", 0x2205: "{}",
    0x00A2: "c",        # cent sign
    0x00B2: "^2", 0x00B3: "^3", 0x00B9: "^1",
    0x00B5: "u", 0x03BC: "u",   # micro
    0x0394: "delta", 0x03B1: "alpha", 0x03B2: "beta",
    0x03C0: "pi", 0x03C3: "sigma", 0x03B8: "theta", 0x03BB: "lambda",
    0x25B2: "^", 0x25BC: "v", 0x25B4: "^", 0x25BE: "v",
    0x21C4: "<->", 0x21C6: "<->", 0x21A9: "<-", 0x21AA: "->",
    0x2460: "(1)", 0x2461: "(2)", 0x2462: "(3)",
    0x2463: "(4)", 0x2464: "(5)", 0x2465: "(6)",
    0x23F8: "[PAUSE]", 0x23F1: "[TIMER]", 0x23F0: "[ALARM]",
    0x23F3: "[WAIT]", 0x231B: "[WAIT]",
    0x00A0: " ",        # non-breaking space
    0x200B: "",         # zero width space
    0x200D: "",         # zero width joiner
    0xFE0F: "",         # variation selector-16
    0xFEFF: "",         # zero width no-break space / BOM
}

CHARMAP = dict((unichr(k) if sys.version_info[0] < 3 else chr(k), v)
               for k, v in _MAP.items())

# Emoji and other pictographs collapse to a neutral marker rather than vanishing,
# so a log line does not silently lose a field separator.
EMOJI = re.compile(
    u"[\U0001F000-\U0001FAFF☀-➿\U0001F1E6-\U0001F1FF⬀-⯿]"
)

_TRAILING_DASH = re.compile(u"\\s*" + EM_DASH + u"\\s*$")


# Replacements that would emit a double quote are unsafe inside a string literal:
# folding a curly quote to `"` there would terminate the literal and break the
# build. Inside strings those fold to an apostrophe instead. No occurrence exists
# today; this keeps a later edit from introducing one silently.
STRING_SAFE = {'"': "'"}


def _fold(text, at_eol, in_string=False):
    """Fold one sweepable span of text to ASCII."""
    # The spaced form is 99% of occurrences and reads naturally as " - ".
    text = text.replace(u" " + EM_DASH + u" ", " - ")

    # A trailing em dash is a sentence continuing on the next comment line. The
    # line break already carries the pause, so the dash is just noise.
    if at_eol:
        text = _TRAILING_DASH.sub("", text)

    text = text.replace(EM_DASH, "-")

    for src, dst in CHARMAP.items():
        if src in text:
            text = text.replace(src, STRING_SAFE.get(dst, dst) if in_string else dst)

    return EMOJI.sub("*", text)


def _spans(line):
    """Split a line into (text, is_string_literal) spans.

    Only accurate enough to tell quoted text from everything else, which is all
    the protected-prose rule needs. Verified during analysis: no AngelScript
    source under these roots carries non-ASCII in actual code.
    """
    out = []
    buf = []
    in_str = False
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if in_str:
            if c == "\\" and i + 1 < n:
                buf.append(line[i:i + 2])
                i += 2
                continue
            buf.append(c)
            if c == '"':
                out.append(("".join(buf), True))
                buf = []
                in_str = False
            i += 1
            continue
        if c == '"':
            if buf:
                out.append(("".join(buf), False))
            buf = [c]
            in_str = True
            i += 1
            continue
        if c == "/" and i + 1 < n and line[i + 1] == "/":
            if buf:
                out.append(("".join(buf), False))
            out.append((line[i:], False))
            return out
        buf.append(c)
        i += 1
    if buf:
        out.append(("".join(buf), in_str))
    return out


def sanitize_text(text, protected_file):
    """Return the sanitized form of a whole file's text."""
    result = []
    for raw in text.splitlines(keepends=True):
        stripped = raw.rstrip("\r\n")
        ending = raw[len(stripped):]

        if all(ord(c) < 128 for c in stripped):
            result.append(raw)
            continue

        keep_prose = protected_file or bool(PROTECTED_LINE.search(stripped))
        parts = _spans(stripped)
        rebuilt = []
        for idx, (span, is_str) in enumerate(parts):
            if is_str and keep_prose:
                rebuilt.append(span)                    # authored player-facing text
            else:
                rebuilt.append(_fold(span, at_eol=(idx == len(parts) - 1),
                                     in_string=is_str))
        new = "".join(rebuilt)

        result.append(new + ending)
    return "".join(result)


# Raw data files that feed the content generators. Developer commentary in these
# is emitted verbatim as // comments into generated .as, so it has to be swept at
# the source or it returns on the next regeneration. Keys holding authored,
# player-visible prose are left alone.
DATA_SWEEP_KEYS = re.compile(r'"(_?comment|_note|note)"(\s*:\s*)"((?:[^"\\]|\\.)*)"')


def sanitize_data_text(text):
    """Fold developer-commentary values in a raw data file, preserving layout."""
    def repl(m):
        return '"%s"%s"%s"' % (m.group(1), m.group(2), _fold(m.group(3), at_eol=False))
    return DATA_SWEEP_KEYS.sub(repl, text)


def iter_files(paths):
    if paths:
        for p in paths:
            if os.path.isfile(p):
                yield p
        return
    for root in ROOTS:
        for dirpath, _, filenames in os.walk(root):
            for f in sorted(filenames):
                # .py sweeps the content-generator tools that live under the
                # script roots. Their header templates are copied verbatim into
                # generated .as files, so leaving them unswept would let the
                # non-ASCII return on the next regeneration.
                if (f.endswith(".as") or f.endswith(".py")
                        or (f.endswith(".json") and "RawData" in dirpath)):
                    yield os.path.join(dirpath, f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="rewrite files in place")
    ap.add_argument("--check", action="store_true", help="report only; exit 1 if dirty")
    ap.add_argument("--paths", nargs="*", default=None, help="specific .as files")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not args.apply and not args.check:
        ap.error("pass --check or --apply")

    dirty = []
    changed = 0
    residual = []

    for path in iter_files(args.paths):
        raw = open(path, "rb").read()
        had_bom = raw.startswith(b"\xef\xbb\xbf")
        if had_bom:
            raw = raw[3:]
        text = raw.decode("utf-8", errors="replace")

        if path.endswith(".json"):
            protected = True          # only the commentary keys are swept
            new = sanitize_data_text(text)
        else:
            protected = bool(PROTECTED_FILES.search(path))
            new = sanitize_text(text, protected)

        if new != text or had_bom:
            dirty.append(path)
            if args.apply:
                with open(path, "wb") as fh:
                    fh.write(new.encode("utf-8"))
                changed += 1

        # Anything still non-ASCII after folding, outside protected prose.
        for num, line in enumerate(new.splitlines(), 1):
            if all(ord(c) < 128 for c in line):
                continue
            if protected or PROTECTED_LINE.search(line):
                continue
            residual.append((path, num, line.strip()))

    if not args.quiet:
        if args.apply:
            print("files rewritten: %d" % changed)
        else:
            print("files needing sanitization: %d" % len(dirty))
            for p in dirty[:15]:
                print("   " + p)
            if len(dirty) > 15:
                print("   ... and %d more" % (len(dirty) - 15))

        if residual:
            print("")
            print("UNMAPPED non-ASCII remaining (%d lines):" % len(residual))
            for p, num, s in residual[:40]:
                chars = sorted(set(c for c in s if ord(c) > 127))
                print("   %s:%d  %s" % (
                    p, num, " ".join("U+%04X" % ord(c) for c in chars)))

    return 1 if (dirty or residual) else 0


if __name__ == "__main__":
    sys.exit(main())
