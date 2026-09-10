#!/usr/bin/env python3
"""
Sanitize the AngelScript sources that ship inside the packaged game.

The AngelScript fork stages the project's `Script` folder (and the Script root of
every enabled plugin) as loose source next to the executable, so everything under
the roots below is readable by anyone who owns the game. This tool folds those
sources to plain ASCII and keeps them that way.

Only comments are rewritten. The contents of a string literal are NEVER touched:
a literal is program data, and folding it changes what the game does. That is not
hypothetical - folding U+2B50 to "*" inside Get_RarityStars silently turned the
movie-mixing rarity stars into asterisks, and it reached players because nobody
re-reads a mechanical sweep.

Non-ASCII inside a literal is REPORTED instead, for a human to decide: either the
line builds FText/NSLOCTEXT (player-facing text, exempt by design) or it is meant
to be ASCII and the author writes it that way.

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


def _fold(text, at_eol):
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
            text = text.replace(src, dst)

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


def sanitize_text(text, protected_file, literal_findings=None, path=None):
    """Fold the comments in a file's text; never touch its string literals.

    literal_findings collects (path, line, codepoints, line text) for every
    literal carrying non-ASCII, so the caller can report what it refused to
    rewrite. protected_file no longer gates the fold - no literal is folded in
    any file - but it still suppresses the finding for files whose literals are
    authored prose by definition.
    """
    result = []
    for lineno, raw in enumerate(text.splitlines(keepends=True), 1):
        stripped = raw.rstrip("\r\n")
        ending = raw[len(stripped):]

        if all(ord(c) < 128 for c in stripped):
            result.append(raw)
            continue

        exempt = protected_file or bool(PROTECTED_LINE.search(stripped))
        parts = _spans(stripped)
        rebuilt = []
        for idx, (span, is_str) in enumerate(parts):
            if is_str:
                # A string literal is program-visible data, so this tool leaves it
                # exactly as written and reports it instead. Rewriting it would turn
                # a hygiene sweep into a behaviour change - see the module docstring.
                if (literal_findings is not None and not exempt
                        and any(ord(c) > 127 for c in span)):
                    codes = sorted({ord(c) for c in span if ord(c) > 127})
                    literal_findings.append((path, lineno, codes, stripped.strip()))
                rebuilt.append(span)
            else:
                rebuilt.append(_fold(span, at_eol=(idx == len(parts) - 1)))

        result.append("".join(rebuilt) + ending)
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


def selftest():
    """Pin the one invariant this tool exists to keep: comments fold, literals do not.

    There is no other test harness in this repo and the failure mode is silent - a
    fold inside a literal changes what the game renders and nothing complains.
    Folding U+2B50 to "*" is exactly how the movie-mixing rarity stars became
    asterisks, so that case is pinned by codepoint rather than by a pasted glyph.
    """
    chr_ = unichr if sys.version_info[0] < 3 else chr
    star, dash = chr_(0x2B50), chr_(0x2014)
    failures = []

    def case(label, src, want, want_findings, protected=False):
        found = []
        got = sanitize_text(src, protected, found, "selftest.as")
        if got != want or len(found) != want_findings:
            failures.append((label, got, len(found), want, want_findings))

    case("a star literal survives untouched",
         'return "' + star * 3 + '";', 'return "' + star * 3 + '";', 1)
    case("a comment still folds",
         "// a " + dash + " b", "// a - b", 0)
    case("an FText line is preserved and not reported",
         'return FText::FromString("' + star + '");',
         'return FText::FromString("' + star + '");', 0)
    case("protected-file prose is preserved and not reported",
         'Say("x' + dash + '");', 'Say("x' + dash + '");', 0, protected=True)
    case("comment folds while the literal on the same line survives",
         'Log("' + star + '"); // a ' + dash + ' b',
         'Log("' + star + '"); // a - b', 1)

    total = 5
    once = sanitize_text('Log("' + star + '"); // ' + dash, False)
    total += 1
    if sanitize_text(once, False) != once:
        failures.append(("fold is idempotent", once, 0, once, 0))

    for label, got, ngot, want, nwant in failures:
        print("  FAIL " + label)
        print("       got  %r (%d findings)" % (got, ngot))
        print("       want %r (%d findings)" % (want, nwant))
    print("selftest: %d passed, %d failed" % (total - len(failures), len(failures)))
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="rewrite files in place")
    ap.add_argument("--check", action="store_true", help="report only; exit 1 if dirty")
    ap.add_argument("--paths", nargs="*", default=None, help="specific .as files")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="run the built-in invariant checks and exit")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.apply and not args.check:
        ap.error("pass --check or --apply")

    dirty = []
    changed = 0
    residual = []
    literal_findings = []

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
            new = sanitize_text(text, protected, literal_findings, path)

        if new != text or had_bom:
            dirty.append(path)
            if args.apply:
                with open(path, "wb") as fh:
                    fh.write(new.encode("utf-8"))
                changed += 1

        # A codepoint CHARMAP does not cover, still sitting in a COMMENT after the
        # fold. String literals are never folded and are reported separately, so
        # they are excluded here rather than counted twice.
        for num, line in enumerate(new.splitlines(), 1):
            if all(ord(c) < 128 for c in line):
                continue
            if protected or PROTECTED_LINE.search(line):
                continue
            comment_only = "".join(sp for sp, is_str in _spans(line) if not is_str)
            if any(ord(c) > 127 for c in comment_only):
                residual.append((path, num, comment_only.strip()))

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

    if literal_findings:
        print("")
        print("NON-ASCII INSIDE A STRING LITERAL - not rewritten, decide by hand (%d):"
              % len(literal_findings))
        for path, num, codes, line in literal_findings[:40]:
            print("   %s:%d  %s" % (path, num, " ".join("U+%04X" % c for c in codes)))
            print("       %s" % line[:110])
        if len(literal_findings) > 40:
            print("   ... and %d more" % (len(literal_findings) - 40))
        print("")
        print("   A literal is program data - folding it changes what the game does.")
        print("   Either build the line as FText/NSLOCTEXT (player-facing text is")
        print("   exempt by design) or write the string in ASCII deliberately.")

    return 1 if (dirty or residual or literal_findings) else 0


if __name__ == "__main__":
    sys.exit(main())
