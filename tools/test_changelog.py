#!/usr/bin/env python3
"""Tests of tools/changelog.py against the fixtures in tools/tests/changelog/.
Usage: python3 tools/test_changelog.py"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "changelog.py")
FIXTURES = os.path.join(HERE, "tests", "changelog")


def run(*args):
    return subprocess.run([sys.executable, "-I", TOOL] + list(args), capture_output=True, text=True,
                          encoding="utf-8")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class ChangelogTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "CHANGELOG.md")
        shutil.copy(os.path.join(FIXTURES, "CHANGELOG.md"), self.path)

    def tearDown(self):
        shutil.rmtree(self.dir)

    def test_cut(self):
        r = run("cut", self.path, "--now", "2026-11-21 13:05")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "2026-11-21 13:05")
        self.assertEqual(read(self.path), read(os.path.join(FIXTURES, "cut-expected.md")))

    def test_cut_empty_unreleased_fails(self):
        run("cut", self.path, "--now", "2026-11-21 13:05")
        before = read(self.path)
        r = run("cut", self.path, "--now", "2026-11-21 14:00")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Unreleased is empty", r.stderr)
        self.assertEqual(read(self.path), before)

    def test_cut_default_time_is_utc_minutes(self):
        r = run("cut", self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout.strip(), r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$")
        self.assertIn("## %s UTC" % r.stdout.strip(), read(self.path))

    def test_notes_markdown(self):
        run("cut", self.path, "--now", "2026-11-21 13:05")
        r = run("notes", self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.startswith("- Gold flies to you"))
        self.assertTrue(r.stdout.rstrip().endswith("wrapped over two lines."))

    def test_notes_old_heading(self):
        r = run("notes", self.path)  # newest dated section without " UTC"
        self.assertEqual(r.stdout.strip(), "Re-upload of the previous update.")

    def test_notes_bbcode(self):
        run("cut", self.path, "--now", "2026-11-21 13:05")
        r = run("notes", self.path, "--bbcode")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, read(os.path.join(FIXTURES, "changenote-expected.txt")))

    def test_check(self):
        run("cut", self.path, "--now", "2026-11-21 13:05")
        self.assertEqual(run("check", self.path, "2026-11-21-1305").returncode, 0)
        r = run("check", self.path, "2026-11-21-1306")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("newest release is 2026-11-21 13:05", r.stderr)
        self.assertNotEqual(run("check", self.path, "2026-11-21 13:05").returncode, 0)

    def test_check_unreleased_not_empty(self):
        r = run("check", self.path, "2026-11-18-1451")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Unreleased is not empty", r.stderr)


if __name__ == "__main__":
    unittest.main()
