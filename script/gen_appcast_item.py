#!/usr/bin/env python3
"""Prepend a new <item> to appcast.xml for a given Mimir release."""

import argparse
import datetime
import os
import sys

MIN_SYSTEM_VERSION = "14.0"


def md_to_html(text):
    """Convert the subset of markdown used in Mimir release notes to HTML."""
    import re
    def inline(s):
        # **bold** → <b>bold</b>, applied inside paragraphs, list items, and blockquotes.
        return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    lines = text.strip().splitlines()
    out = []
    in_ul = False
    for line in lines:
        # h4 → bold paragraph
        if line.startswith("#### "):
            if in_ul:
                out.append("</ul>")
                in_ul = False
            out.append(f"<p><b>{line[5:].strip()}</b></p>")
        # list item
        elif line.startswith("- "):
            if not in_ul:
                out.append("<ul>")
                in_ul = True
            out.append(f"<li>{inline(line[2:].strip())}</li>")
        # horizontal rule (EN/TR separator)
        elif line.strip() in ("---", "—"):
            if in_ul:
                out.append("</ul>")
                in_ul = False
            out.append("<hr>")
        # blockquote
        elif line.startswith("> "):
            if in_ul:
                out.append("</ul>")
                in_ul = False
            out.append(f"<blockquote>{inline(line[2:].strip())}</blockquote>")
        # bold text paragraph
        elif line.startswith("**") and line.endswith("**"):
            if in_ul:
                out.append("</ul>")
                in_ul = False
            out.append(f"<p><b>{line[2:-2]}</b></p>")
        # blank line → close list if open
        elif line.strip() == "":
            if in_ul:
                out.append("</ul>")
                in_ul = False
        else:
            if in_ul:
                out.append("</ul>")
                in_ul = False
            # inline bold
            line = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", line)
            out.append(f"<p>{line.strip()}</p>")
    if in_ul:
        out.append("</ul>")
    return "\n".join(out)


def build_item(version, build_number, url, signature, length, notes, pub_date):
    return (
        f"    <item>\n"
        f"      <title>Mimir {version}</title>\n"
        f"      <sparkle:version>{build_number}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        f"      <pubDate>{pub_date}</pubDate>\n"
        f"      <description><![CDATA[\n{md_to_html(notes)}\n      ]]></description>\n"
        f"      <enclosure\n"
        f"        url=\"{url}\"\n"
        f"        sparkle:edSignature=\"{signature}\"\n"
        f"        length=\"{length}\"\n"
        f"        type=\"application/octet-stream\"\n"
        f"        sparkle:minimumSystemVersion=\"{MIN_SYSTEM_VERSION}\"/>\n"
        f"    </item>\n"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--date", default=None)
    args = parser.parse_args()

    pub_date = args.date or datetime.datetime.utcnow().strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )

    if not os.path.exists(args.appcast):
        print(f"ERROR: {args.appcast} not found", file=sys.stderr)
        sys.exit(1)

    content = open(args.appcast, encoding="utf-8").read()

    # Insert before the first existing <item>, or before </channel> if none
    marker = "<item>"
    fallback = "</channel>"
    insert_at = content.find(marker)
    if insert_at == -1:
        insert_at = content.find(fallback)
        if insert_at == -1:
            print("ERROR: could not find insertion point in appcast.xml", file=sys.stderr)
            sys.exit(1)

    new_item = build_item(
        args.version, args.build_number, args.url,
        args.signature, args.length, args.notes, pub_date
    )
    updated = content[:insert_at] + new_item + "\n" + content[insert_at:]

    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(updated)

    print(f"appcast.xml → v{args.version} added")


if __name__ == "__main__":
    main()
