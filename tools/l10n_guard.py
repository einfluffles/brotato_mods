#!/usr/bin/env python3
"""Checks that the mods' player-visible texts go through their translations.csv.

1. A string literal with two or more letters assigned to .text / hint_tooltip, or passed to
   add_item / set_text / set_tooltip / a ..._button() helper as its first argument (also through
   a constant of the same file), in mods/*/src/ is an error, unless it is a translation key
   (upper case, digits, underscores) or its line carries "# l10n: keep". Files in ALLOWLIST are
   not converted yet and skipped; an entry that has nothing to report any more is an error too.
2. In a mod with src/<mod_id>/translations.csv: every key literal with the CSV's prefix (BT_ in
   brotato:together) in the mod's sources and tests is a key of the CSV, and every key of the CSV
   is used in the sources.

Usage: tools/l10n_guard.py [repo root]   (run by tools/lint.sh)
"""
import csv
import pathlib
import re
import sys

# Files not converted yet (repo-relative). Every mod is converted: keep it empty.
ALLOWLIST = set()

KEEP = "# l10n: keep"
STRING = r'"((?:[^"\\]|\\.)*)"'
SINK = (
    r"(?:\.(?:text|hint_tooltip)\s*\+?=|^\s*hint_tooltip\s*\+?="
    r"|\b(?:add_item|set_text|set_tooltip|\w*button)\()\s*"
)
# A literal, or a constant of the same file that holds one (TITLE, not TITLE.x or TITLE % x).
SINK_LITERAL = re.compile(SINK + STRING)
SINK_CONST = re.compile(SINK + r"([A-Z][A-Z0-9_]*)\b(?!\s*[.(\[%])")
CONST = re.compile(r"^const\s+([A-Z][A-Z0-9_]*)\s*:?=\s*" + STRING)
KEY = re.compile(r"[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*")
FORMAT = re.compile(r"%[-+ 0#]*\d*(?:\.\d+)?[a-zA-Z]")
LETTER = re.compile(r"[^\W\d_]")


def needs_key(literal):
    if KEY.fullmatch(literal):
        return False
    return len(LETTER.findall(FORMAT.sub("", literal))) >= 2


def literal_findings(root):
    findings = []  # (path, line number, literal)
    for path in sorted(root.glob("mods/*/src/**/*.gd")):
        rel = path.relative_to(root).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        consts = {}
        for line in lines:
            match = CONST.match(line)
            if match and KEEP not in line:
                consts[match.group(1)] = match.group(2)
        for number, line in enumerate(lines, 1):
            if KEEP in line or line.lstrip().startswith("#"):
                continue
            shown = [m.group(1) for m in SINK_LITERAL.finditer(line)]
            shown += [consts[m.group(1)] for m in SINK_CONST.finditer(line) if m.group(1) in consts]
            for literal in shown:
                if needs_key(literal):
                    findings.append((rel, number, literal))
    return findings


def key_findings(root):
    errors = []
    for table in sorted(root.glob("mods/*/src/*/translations.csv")):
        mod = table.parents[2]
        with table.open(encoding="utf-8-sig", newline="") as f:
            keys = [row[0] for row in list(csv.reader(f))[1:] if row and row[0]]
        if not keys:
            errors.append("%s: no keys" % table.relative_to(root).as_posix())
            continue
        prefix = keys[0].split("_")[0] + "_"
        used = re.compile('"(' + re.escape(prefix) + r'[A-Z0-9_]+)"')
        in_src = set()
        for folder, names in (("src", in_src), ("tests", set())):
            for path in sorted((mod / folder).glob("**/*.gd")):
                text = path.read_text(encoding="utf-8")
                for match in used.finditer(text):
                    names.add(match.group(1))
                    if match.group(1) not in keys:
                        errors.append(
                            "%s: %s is not in %s"
                            % (path.relative_to(root).as_posix(), match.group(1), table.name)
                        )
        for key in keys:
            if key not in in_src:
                errors.append("%s: %s is used nowhere" % (table.relative_to(root).as_posix(), key))
    return errors


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    errors = []
    flagged = set()
    for rel, number, literal in literal_findings(root):
        flagged.add(rel)
        if rel not in ALLOWLIST:
            errors.append('%s:%d: "%s" is shown untranslated: use a key (or "%s")'
                          % (rel, number, literal, KEEP))
    for rel in sorted(ALLOWLIST - flagged):
        errors.append("%s: on the allowlist of tools/l10n_guard.py, but converted: remove it" % rel)
    errors += key_findings(root)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        sys.exit(1)
    print("l10n guard: ok (%d files on the allowlist)" % len(ALLOWLIST))


if __name__ == "__main__":
    main()
