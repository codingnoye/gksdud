#!/usr/bin/env python3
"""Builds the download page for one release: its buttons get the release's disk image, or its ZIP, and the page shows its tag."""
import argparse
import html
import json
import pathlib
import re
import shutil

ARCHIVES = ("dmg", "zip")


def download_url(release):
    for kind in ARCHIVES:
        for asset in release["assets"]:
            if re.fullmatch(rf"gksdud-\d+(\.\d+)*\.{kind}", asset["name"]):
                return asset["browser_download_url"]
    raise ValueError(f"{release['tag_name']} has no gksdud disk image or ZIP")


def filled(page, release):
    url, tag = html.escape(download_url(release)), html.escape(release["tag_name"])
    page, links = re.subn(r'(data-download href=")[^"]*(")', lambda m: m[1] + url + m[2], page)
    page, versions = re.subn(r'(<span class="meta" data-meta>)[^<]*(</span>)', lambda m: m[1] + tag + m[2], page)
    if not links or not versions:
        raise ValueError("The page has no download button or version to fill")
    return page


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=pathlib.Path, help="The release as GitHub's API returns it")
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    release = json.loads(args.release.read_text())
    shutil.copytree(args.source, args.output)
    page = args.output / "index.html"
    page.write_text(filled(page.read_text(), release))
    print(f"{release['tag_name']}: {download_url(release)}")


if __name__ == "__main__":
    main()
