import base64
import hashlib
import importlib.util
import io
import pathlib
import plistlib
import unittest
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("update_tap", pathlib.Path(__file__).with_name("update-tap.py"))
tap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tap)
OLD = 'cask "gksdud" do\n  version "1.0.0"\n  sha256 "' + 'a' * 64 + '"\nend\n'


class TapTests(unittest.TestCase):
    def test_cask_update_and_immutable_version(self):
        new = tap.updated_cask(OLD, "1.1.0", "b" * 64)
        self.assertIn('version "1.1.0"', new)
        self.assertEqual(tap.updated_cask(OLD, "1.0.0", "a" * 64), OLD)
        for v, sha in [("0.9.0", "a" * 64), ("1.0.0", "b" * 64)]:
            with self.assertRaises(ValueError):
                tap.updated_cask(OLD, v, sha)

    def test_tag_validation(self):
        for tag in ["main", "v1.0.0-rc1", "v1.0.0/../../main", "v01.0.0"]:
            with self.assertRaises(ValueError):
                tap.version(tag)

    def test_release_assets(self):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("gksdud.app/Contents/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": "1.1.0", "CFBundleIdentifier": "io.gksdud.inputswitch"}))
        raw = archive.getvalue()
        digest = hashlib.sha256(raw).hexdigest()
        name = "gksdud-1.1.0-macos-universal.zip"
        root = "https://github.com/codingnoye/gksdud/releases/download/v1.1.0/"
        release = {"tag_name": "v1.1.0", "draft": False, "prerelease": False,
                   "assets": [{"name": n, "browser_download_url": root + n} for n in [name, "SHA256SUMS"]]}
        with patch.object(tap, "download", side_effect=[raw, f"{digest}  {name}\n".encode()]):
            self.assertEqual(tap.verify_release(release, "v1.1.0"), ("1.1.0", digest))
        with patch.object(tap, "download", side_effect=[raw, b"wrong checksum"]):
            with self.assertRaises(ValueError):
                tap.verify_release(release, "v1.1.0")
        for flag in ["draft", "prerelease"]:
            with self.assertRaises(ValueError):
                tap.verify_release(dict(release, **{flag: True}), "v1.1.0")

    def exercise(self, current=OLD, branch_text=None, existing_pr=False, dry_run=False):
        writes = []
        def api(repo, path, method="GET", data=None):
            if method != "GET":
                writes.append((path, method, data))
                return {"html_url": "https://github.com/codingnoye/homebrew-tap/pull/123"}
            if path.startswith("releases/"):
                return {}
            if path == "branches/main":
                return {"commit": {"sha": "base"}}
            if path.startswith("git/matching-refs/"):
                return [{"ref": "refs/heads/release/gksdud-1.1.0"}] if branch_text is not None else []
            if path.startswith("contents/"):
                value = current if path.endswith("ref=base") or branch_text is None else branch_text
                return {"sha": "blob", "content": base64.b64encode(value.encode()).decode()}
            if path.startswith("pulls?"):
                return [{"html_url": "existing"}] if existing_pr else []
            raise AssertionError(path)
        with patch.object(tap, "api", side_effect=api), patch.object(tap, "verify_release", return_value=("1.1.0", "b" * 64)):
            tap.open_update("v1.1.0", dry_run)
        return writes

    def test_new_pr(self):
        writes = self.exercise()
        self.assertEqual([(p, m) for p, m, _ in writes], [
            ("git/refs", "POST"), ("contents/Casks/gksdud.rb", "PUT"), ("pulls", "POST")])
        self.assertEqual(writes[0][2]["ref"], "refs/heads/release/gksdud-1.1.0")

    def test_no_duplicate_or_noop_writes(self):
        new = tap.updated_cask(OLD, "1.1.0", "b" * 64)
        self.assertEqual(self.exercise(current=new), [])
        self.assertEqual(self.exercise(branch_text=new, existing_pr=True), [])
        self.assertEqual(self.exercise(dry_run=True), [])
        with self.assertRaises(ValueError):
            self.exercise(branch_text="manual changes")


if __name__ == "__main__":
    unittest.main()
