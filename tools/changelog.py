#!/usr/bin/env python3
"""A mod's CHANGELOG.md: cut a release, read the newest one, write it as Steam BBCode.

The file has a "## Unreleased" section, then one section per release, newest first, headed
"## YYYY-MM-DD HH:MM UTC" (older ones: "## YYYY-MM-DD HH:MM", US Pacific upload times).

Usage:
  changelog.py cut <CHANGELOG.md> [--now "YYYY-MM-DD HH:MM"]
      Unreleased becomes "## <now> UTC" (default: the current UTC time) under a new empty
      Unreleased. Prints the stamp. Fails when Unreleased is empty.
  changelog.py notes <CHANGELOG.md> [--bbcode]
      Prints the newest dated section's body, as Markdown or as Steam BBCode.
  changelog.py check <CHANGELOG.md> <YYYY-MM-DD-HHMM>
      Fails unless the newest dated section is that release's and Unreleased is empty.
"""
import argparse
import datetime
import re
import sys

HEADING = re.compile(r"^## (.+?)\s*$")
DATED = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})( UTC)?$")
TAG_STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2})-(\d{2})(\d{2})$")


def sections(lines):
    """(title, start, end) per "## " section; the body is lines[start + 1:end]."""
    found = []
    for i, line in enumerate(lines):
        m = HEADING.match(line)
        if m:
            if found:
                found[-1][2] = i
            found.append([m.group(1), i, len(lines)])
    return [tuple(s) for s in found]


def body(lines, section):
    return "\n".join(lines[section[1] + 1:section[2]]).strip("\n")


def unreleased(lines):
    for s in sections(lines):
        if s[0] == "Unreleased":
            return s
    sys.exit("no \"## Unreleased\" section")


def newest_dated(lines):
    for s in sections(lines):
        if DATED.match(s[0]):
            return s
    sys.exit("no dated section")


def cut(path, now):
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    s = unreleased(lines)
    text = body(lines, s).strip()
    if not text:
        sys.exit("%s: Unreleased is empty, nothing to release" % path)
    out = lines[:s[1]] + ["## Unreleased", "", "## %s UTC" % now, "", text, ""] + lines[s[2]:]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    print(now)


def check(path, tag_stamp):
    m = TAG_STAMP.match(tag_stamp)
    if not m:
        sys.exit("tag time %r is not YYYY-MM-DD-HHMM" % tag_stamp)
    want = "%s %s:%s" % m.groups()
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    if body(lines, unreleased(lines)).strip():
        sys.exit("%s: Unreleased is not empty: tag the release PR's merge commit, or cut a new release" % path)
    got = DATED.match(newest_dated(lines)[0]).group(1)
    if got != want:
        sys.exit("%s: newest release is %s, the tag says %s" % (path, got, want))


def link(m):
    text, url = m.groups()
    return "[url=%s]%s[/url]" % (url, text) if re.match(r"https?://", url) else text  # relative: text only


def inline(text):
    parts = re.split(r"(`[^`]*`)", text)
    out = []
    for i, part in enumerate(parts):
        if i % 2:
            out.append(part[1:-1])  # code: plain text
            continue
        part = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, part)
        part = re.sub(r"\*\*(.+?)\*\*", r"[b]\1[/b]", part)
        part = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"[i]\1[/i]", part)
        out.append(part)
    return "".join(out)


def bbcode(markdown):
    """Lists (nested by indentation), paragraphs, ### headings, **bold**, *italic*, `code`, links
    (a relative one becomes its text).
    Wrapped lines are joined: Steam shows every newline."""
    blocks = []  # (kind, indent, text): kind "item", "para" or "head"
    for line in markdown.split("\n"):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        item = re.match(r"^[-*+] (.*)$", stripped)
        head = re.match(r"^#{3,6} (.*)$", stripped)
        if not stripped:
            blocks.append(("blank", 0, ""))
        elif item:
            blocks.append(("item", indent, item.group(1)))
        elif head:
            blocks.append(("head", 0, head.group(1)))
        elif blocks and blocks[-1][0] in ("item", "para"):
            kind, ind, text = blocks[-1]
            blocks[-1] = (kind, ind, text + " " + stripped)
        else:
            blocks.append(("para", 0, stripped))
    out = []
    depth = []  # indents of the open lists
    for kind, indent, text in blocks:
        if kind == "blank":
            continue
        if kind != "item":
            while depth:
                depth.pop()
                out.append("[/list]")
            out.append("[h3]%s[/h3]" % inline(text) if kind == "head" else inline(text))
            continue
        while depth and indent < depth[-1]:
            depth.pop()
            out.append("[/list]")
        if not depth or indent > depth[-1]:
            depth.append(indent)
            out.append("[list]")
        out.append("[*]" + inline(text))
    out.extend("[/list]" for _ in depth)
    return "\n".join(out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cut")
    c.add_argument("path")
    c.add_argument("--now")
    n = sub.add_parser("notes")
    n.add_argument("path")
    n.add_argument("--bbcode", action="store_true")
    k = sub.add_parser("check")
    k.add_argument("path")
    k.add_argument("tag_stamp")
    a = p.parse_args()
    if a.cmd == "cut":
        now = a.now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")
        if not DATED.match(now):
            sys.exit("--now %r is not YYYY-MM-DD HH:MM" % now)
        cut(a.path, now)
    elif a.cmd == "notes":
        with open(a.path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        text = body(lines, newest_dated(lines)).strip()
        print(bbcode(text) if a.bbcode else text)
    else:
        check(a.path, a.tag_stamp)


if __name__ == "__main__":
    main()
