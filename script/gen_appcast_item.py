#!/usr/bin/env python3
"""Prepend a new <item> to appcast.xml for a given Mimir release.

Uses string-based insertion rather than an XML parser — no external
dependencies and no exposure to XXE or entity-expansion attacks.
"""

import argparse
import datetime
import os
import sys

MIN_SYSTEM_VERSION = "14.0"
ITEM_MARKER = "<item>"


def build_item(version, url, signature, length, pub_date):
    return (
        f"    <item>\n"
        f"      <title>Version {version}</title>\n"
        f"      <sparkle:version>{version}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        f"      <pubDate>{pub_date}</pubDate>\n"
        f"      <enclosure\n"
        f"        url=\"{url}\"\n"
        f"        sparkle:edSignature=\"{signature}\"\n"
        f"        length=\"{length}\"\n"
        f"        type=\"application/zip\"\n"
        f"        sparkle:minimumSystemVersion=\"{MIN_SYSTEM_VERSION}\"/>\n"
        f"    </item>\n"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--date", default=None)
    args = parser.parse_args()

    pub_date = args.date or datetime.datetime.utcnow().strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )

    if not os.path.exists(args.appcast):
        print(f"ERROR: {args.appcast} bulunamadı", file=sys.stderr)
        sys.exit(1)

    content = open(args.appcast, encoding="utf-8").read()

    insert_at = content.find(ITEM_MARKER)
    if insert_at == -1:
        print("ERROR: appcast.xml içinde <item> bulunamadı", file=sys.stderr)
        sys.exit(1)

    new_item = build_item(
        args.version, args.url, args.signature, args.length, pub_date
    )
    updated = content[:insert_at] + new_item + "\n" + content[insert_at:]

    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(updated)

    print(f"appcast.xml → v{args.version} eklendi")


if __name__ == "__main__":
    main()
