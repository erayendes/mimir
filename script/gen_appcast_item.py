#!/usr/bin/env python3
"""Prepend a new <item> to appcast.xml for a given Mimir release."""

import argparse
import datetime
import os
import sys

MIN_SYSTEM_VERSION = "14.0"


def build_item(version, build_number, url, signature, length, notes, pub_date):
    return (
        f"    <item>\n"
        f"      <title>Mimir {version}</title>\n"
        f"      <sparkle:version>{build_number}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        f"      <pubDate>{pub_date}</pubDate>\n"
        f"      <description>{notes}</description>\n"
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
