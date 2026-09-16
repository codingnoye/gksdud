#!/usr/bin/env python3
"""Open a tap PR for a published release. Never merge or replace release assets."""
import argparse
import base64
import hashlib
import io
import json
import os
import plistlib
import re
import subprocess
import urllib.request
import zipfile

SOURCE = "codingnoye/gksdud"
TAP = "codingnoye/homebrew-tap"
PATH = "Casks/gksdud.rb"


def api(repo, path, method="GET", data=None):
    env = os.environ.copy()
    env["GH_TOKEN"] = os.environ["TAP_GITHUB_TOKEN" if repo == TAP else "GH_TOKEN"]
    args = ["gh", "api", "--method", method, f"repos/{repo}/{path}"]
    if data is not None:
        args += ["--input", "-"]
    result = subprocess.run(args, input=json.dumps(data) if data is not None else None,
                            text=True, capture_output=True, env=env, check=True, timeout=60)
    return json.loads(result.stdout) if result.stdout.strip() else None


def version(tag):
    if not re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", tag):
        raise ValueError("Expected a stable vX.Y.Z tag")
    return tag[1:]


def download(url, limit):
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Release asset exceeds size limit")
    return data


def verify_release(release, tag):
    v = version(tag)
    if release["tag_name"] != tag or release["draft"] or release["prerelease"]:
        raise ValueError("Only published stable releases can update the tap")
    name = f"gksdud-{v}-macos-universal.zip"
    root = f"https://github.com/{SOURCE}/releases/download/{tag}/"
    assets = release["assets"]
    for asset_name in (name, "SHA256SUMS"):
        matches = [a for a in assets if a["name"] == asset_name]
        if len(matches) != 1 or matches[0]["browser_download_url"] != root + asset_name:
            raise ValueError("Missing or unexpected release asset")
    archive = download(root + name, 20 * 1024 * 1024)
    digest = hashlib.sha256(archive).hexdigest()
    checksums = download(root + "SHA256SUMS", 4096).decode("utf-8")
    if checksums != f"{digest}  {name}\n":
        raise ValueError("Published checksum mismatch")
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        info = bundle.getinfo("gksdud.app/Contents/Info.plist")
        if info.file_size > 65536:
            raise ValueError("Unexpected Info.plist size")
        plist = plistlib.loads(bundle.read(info))
    if plist.get("CFBundleShortVersionString") != v or plist.get("CFBundleIdentifier") != "io.gksdud.inputswitch":
        raise ValueError("App identity or version mismatch")
    return v, digest


def updated_cask(text, target, digest):
    versions = re.findall(r'^  version "([0-9]+\.[0-9]+\.[0-9]+)"$', text, re.M)
    hashes = re.findall(r'^  sha256 "([a-f0-9]{64})"$', text, re.M)
    if len(versions) != 1 or len(hashes) != 1 or not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise ValueError("Unexpected Cask format")
    current = versions[0]
    if tuple(map(int, target.split('.'))) < tuple(map(int, current.split('.'))):
        raise ValueError("Refusing a tap downgrade")
    if current == target and hashes[0] != digest:
        raise ValueError("Refusing to replace an existing version's checksum")
    return text.replace(f'  version "{current}"', f'  version "{target}"', 1).replace(
        f'  sha256 "{hashes[0]}"', f'  sha256 "{digest}"', 1)


def open_update(tag, dry_run=False):
    version(tag)  # Validate before forming any API route.
    v, digest = verify_release(api(SOURCE, f"releases/tags/{tag}"), tag)
    base = api(TAP, "branches/main")["commit"]["sha"]
    source = api(TAP, f"contents/{PATH}?ref={base}")
    original = base64.b64decode(source["content"]).decode("utf-8")
    updated = updated_cask(original, v, digest)
    if updated == original:
        print(f"Tap already contains {v} with the published checksum. No PR needed.")
        return
    if dry_run:
        print(f"Verified {tag}. Would open a tap update PR; no changes made.")
        return
    branch = f"release/gksdud-{v}"
    refs = api(TAP, f"git/matching-refs/heads/{branch}")
    if not any(ref["ref"] == f"refs/heads/{branch}" for ref in refs):
        api(TAP, "git/refs", "POST", {"ref": f"refs/heads/{branch}", "sha": base})
    existing = api(TAP, f"contents/{PATH}?ref={branch}")
    existing_text = base64.b64decode(existing["content"]).decode("utf-8")
    if existing_text == original:
        api(TAP, f"contents/{PATH}", "PUT", {
            "message": f"[CHORE] Update gksdud to {v}", "branch": branch,
            "sha": existing["sha"], "content": base64.b64encode(updated.encode()).decode()})
    elif existing_text != updated:
        raise ValueError("Update branch contains different changes; review it manually")
    # Never overwrite a branch, duplicate a PR, or merge automatically.
    prs = api(TAP, f"pulls?state=open&base=main&head=codingnoye:{branch}")
    if prs:
        print(f"Existing PR: {prs[0]['html_url']}")
        return
    pr = api(TAP, "pulls", "POST", {
        "title": f"[CHORE] gksdud {v}", "head": branch, "base": "main",
        "body": f"## Update\n\nRelease: https://github.com/{SOURCE}/releases/tag/{tag}\n\n"
                f"Published ZIP checksum verified: `{digest}`.\n\n"
                "Only the Cask version and checksum change. Squash merge after checks pass."})
    print(f"Created PR: {pr['html_url']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        open_update(args.tag, args.dry_run)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"GitHub API command failed (exit {error.returncode}); check token permissions and repository state.")
