#!/usr/bin/env python3
"""Tests of tools/zip_guard.py on zips and source trees planted in a temporary folder.
Usage: python3 tools/test_zip_guard.py"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "zip_guard.py")
MOD_ID = "einfluffles-Example"
CLEAN_GD = b"extends Node\nvar buf := StreamPeerBuffer.new()  # no socket\n"


def run(*args):
    return subprocess.run([sys.executable, "-I", TOOL] + list(args), capture_output=True, text=True,
                          encoding="utf-8")


class ZipGuardTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.src = os.path.join(self.root, "mods", "example", "src", MOD_ID)
        os.makedirs(self.src)
        self.write(os.path.join(self.src, "manifest.json"), b'{"name": "Example"}\n')
        self.write(os.path.join(self.src, "mod_main.gd"), CLEAN_GD)
        self.dist = os.path.join(self.root, "dist")
        os.makedirs(os.path.join(self.dist, "Example"))

    def tearDown(self):
        shutil.rmtree(self.root)

    @staticmethod
    def write(path, data):
        with open(path, "wb") as f:
            f.write(data)

    # The layout tools/package.sh writes, plus extra entries.
    def make_zip(self, extra=(), name="Example"):
        path = os.path.join(self.dist, name, name + ".zip")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("mods-unpacked/", b"")
            z.writestr("mods-unpacked/%s/" % MOD_ID, b"")
            z.writestr("mods-unpacked/%s/manifest.json" % MOD_ID, b'{"name": "Example"}\n')
            z.writestr("mods-unpacked/%s/mod_main.gd" % MOD_ID, CLEAN_GD)
            z.writestr("mods-unpacked/%s/LICENSE" % MOD_ID, b"MIT\n")
            for entry, data in extra:
                z.writestr(entry, data)
        return path

    def zips(self):
        return run("--root", self.root, "zips", self.dist)

    def test_clean_zip_passes(self):
        self.make_zip()
        result = self.zips()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ok   Example/Example.zip", result.stdout)

    def test_socket_class_in_script_fails(self):
        self.make_zip([("mods-unpacked/%s/net/x.gd" % MOD_ID,
                        b"extends Node\n\nvar peer = NetworkedMultiplayerENet.new()\n")])
        result = self.zips()
        self.assertEqual(result.returncode, 1)
        self.assertIn("net/x.gd:3: NetworkedMultiplayerENet", result.stderr)

    def test_every_socket_class_fails(self):
        for cls in ["PacketPeerUDP", "StreamPeerTCP", "TCP_Server", "UDPServer",
                    "WebSocketServer", "WebSocketClient", "WebSocketMultiplayerPeer"]:
            scene = ("script = %s\n" % cls).encode()
            self.make_zip([("mods-unpacked/%s/ui/x.tscn" % MOD_ID, scene)])
            result = self.zips()
            self.assertEqual(result.returncode, 1, cls)
            self.assertIn("x.tscn:1: " + cls, result.stderr)

    def test_file_outside_mod_folder_fails(self):
        for entry in ["README.md", "mods-unpacked/stray.gd", "other/%s/x.gd" % MOD_ID]:
            self.make_zip([(entry, b"x\n")])
            result = self.zips()
            self.assertEqual(result.returncode, 1, entry)
            self.assertIn("outside mods-unpacked/<mod_id>/", result.stderr)

    def test_second_mod_folder_fails(self):
        self.make_zip([("mods-unpacked/einfluffles-TogetherLocal/manifest.json", b"{}\n")])
        result = self.zips()
        self.assertEqual(result.returncode, 1)
        self.assertIn("einfluffles-TogetherLocal/ is no mod of this repo", result.stderr)
        self.assertIn("2 mod folders", result.stderr)

    def test_unsafe_paths_fail(self):
        for entry in ["mods-unpacked/%s/../../evil.gd" % MOD_ID, "/abs.gd", "C:/x.gd"]:
            self.make_zip([(entry, b"x\n")])
            result = self.zips()
            self.assertEqual(result.returncode, 1, entry)
            self.assertIn("unsafe path", result.stderr)

    def test_missing_manifest_fails(self):
        path = os.path.join(self.dist, "Example", "Example.zip")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("mods-unpacked/%s/mod_main.gd" % MOD_ID, CLEAN_GD)
        result = self.zips()
        self.assertEqual(result.returncode, 1)
        self.assertIn("manifest.json missing", result.stderr)

    def test_no_zip_fails(self):
        result = self.zips()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no .zip", result.stderr)

    def test_src_clean_passes(self):
        result = run("--root", self.root, "src")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_src_socket_class_fails(self):
        os.makedirs(os.path.join(self.src, "net"))
        self.write(os.path.join(self.src, "net", "y.gd"), b"# uses PacketPeerUDP\n")
        result = run("--root", self.root, "src")
        self.assertEqual(result.returncode, 1)
        self.assertIn("mods/example/src/%s/net/y.gd:1: PacketPeerUDP" % MOD_ID, result.stderr)

    def test_dev_code_outside_src_is_not_scanned(self):
        dev = os.path.join(self.root, "mods", "example", "dev")
        os.makedirs(dev)
        self.write(os.path.join(dev, "wire.gd"), b"var peer = NetworkedMultiplayerENet.new()\n")
        result = run("--root", self.root, "src")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
