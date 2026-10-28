import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("build_site", pathlib.Path(__file__).with_name("build-site.py"))
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)
PAGE = (pathlib.Path(__file__).parent.parent / "site" / "index.html").read_text()
BASE = "https://github.com/codingnoye/gksdud/releases/download/v2.2.0/"


def release(*names, tag="v2.2.0"):
    return {"tag_name": tag, "assets": [{"name": n, "browser_download_url": BASE + n} for n in names]}


class BuildSiteTests(unittest.TestCase):
    def test_disk_image_comes_before_the_zip(self):
        rel = release("SHA256SUMS", "gksdud-2.2.0.zip", "gksdud-2.2.0.dmg")
        self.assertEqual(site.download_url(rel), BASE + "gksdud-2.2.0.dmg")
        self.assertEqual(site.download_url(release("gksdud-2.0.1.0.8.zip")), BASE + "gksdud-2.0.1.0.8.zip")

    def test_only_the_app_archives_count(self):
        with self.assertRaises(ValueError):
            site.download_url(release("SHA256SUMS", "gksdud-2.2.0-macos-universal.zip", "other-2.2.0.dmg"))

    def test_every_button_and_version_of_the_page_is_filled(self):
        page = site.filled(PAGE, release("gksdud-2.2.0.dmg"))
        self.assertEqual(page.count(f'data-download href="{BASE}gksdud-2.2.0.dmg"'), PAGE.count("data-download href="))
        self.assertEqual(page.count('data-meta>v2.2.0</span>'), PAGE.count("data-meta>"))
        self.assertNotIn("releases/latest", page)

    def test_a_page_without_buttons_is_refused(self):
        with self.assertRaises(ValueError):
            site.filled("<p>gksdud</p>", release("gksdud-2.2.0.dmg"))


if __name__ == "__main__":
    unittest.main()
