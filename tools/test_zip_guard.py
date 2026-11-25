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

    def test_every_network_class_fails(self):
        for cls in ["PacketPeerUDP", "StreamPeerTCP", "TCP_Server", "UDPServer",
                    "WebSocketServer", "WebSocketClient", "WebSocketMultiplayerPeer",
                    "HTTPRequest", "HTTPClient", "StreamPeerSSL", "PacketPeerDTLS", "DTLSServer",
                    "WebRTCPeerConnection", "WebRTCDataChannel", "WebRTCMultiplayer", "UPNP",
                    "UPNPDevice"]:
            scene = ("script = %s\n" % cls).encode()
            self.make_zip([("mods-unpacked/%s/ui/x.tscn" % MOD_ID, scene)])
            result = self.zips()
            self.assertEqual(result.returncode, 1, cls)
            self.assertIn("network class in shipped code: mods-unpacked/%s/ui/x.tscn:1: %s"
                          % (MOD_ID, cls), result.stderr)

    # Words that only contain a class name are no class.
    def test_longer_words_pass(self):
        self.make_zip([("mods-unpacked/%s/x.gd" % MOD_ID,
                        b"var my_HTTPRequests := 0\nvar UPNPish_text := \"\"  # TCP_ServerX\n")])
        result = self.zips()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_native_file_fails(self):
        for name in ["bin/x.dll", "bin/libx.so", "bin/libx.so.1", "bin/x.dylib", "x.gdnlib",
                     "x.gdns", "extra.pck", "compiled.gdc", "tool.exe", "bin/X.DLL"]:
            self.make_zip([("mods-unpacked/%s/%s" % (MOD_ID, name), b"\x00\x01binary")])
            result = self.zips()
            self.assertEqual(result.returncode, 1, name)
            self.assertIn("native or binary file in shipped code: mods-unpacked/%s/%s"
                          % (MOD_ID, name), result.stderr)

    def test_other_suffixes_pass(self):
        self.make_zip([("mods-unpacked/%s/%s" % (MOD_ID, name), b"x\n")
                       for name in ["icon.png", "texts.csv", "a.sound.ogg", "notes.gdc.md"]])
        result = self.zips()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dev_mod_named_fails(self):
        for text in [b'var dev = "/root/ModLoader/einfluffles-TogetherLocal"\n',
                     b'var role := OS.get_environment("BT_LOCAL_ROLE")\n']:
            self.make_zip([("mods-unpacked/%s/net/x.gd" % MOD_ID, text)])
            result = self.zips()
            self.assertEqual(result.returncode, 1, text)
            self.assertIn("local-play dev mod named in shipped code: mods-unpacked/%s/net/x.gd:1:"
                          % MOD_ID, result.stderr)

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

    # A dev mod (mods/<folder>/dev/<mod_id>/, the local-play emulator) has a manifest too, but it
    # is no mod of the repo: a zip of it, or with it, fails.
    def test_dev_mod_zip_fails(self):
        dev = os.path.join(self.root, "mods", "example", "dev", "einfluffles-ExampleLocal")
        os.makedirs(dev)
        self.write(os.path.join(dev, "manifest.json"), b'{"name": "ExampleLocal"}\n')
        path = os.path.join(self.dist, "Local", "Local.zip")
        os.makedirs(os.path.dirname(path))
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("mods-unpacked/einfluffles-ExampleLocal/manifest.json", b"{}\n")
            z.writestr("mods-unpacked/einfluffles-ExampleLocal/wire.gd",
                       b"var peer = NetworkedMultiplayerENet.new()\n")
        self.make_zip([("mods-unpacked/einfluffles-ExampleLocal/manifest.json", b"{}\n")])
        result = self.zips()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Local.zip: mods-unpacked/einfluffles-ExampleLocal/ is no mod of this repo",
                      result.stderr)
        self.assertIn("Example.zip: mods-unpacked/einfluffles-ExampleLocal/ is no mod",
                      result.stderr)
        self.assertIn("wire.gd:1: NetworkedMultiplayerENet", result.stderr)

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

    def test_src_new_rules_fail(self):
        os.makedirs(os.path.join(self.src, "net"))
        self.write(os.path.join(self.src, "net", "h.gd"), b"var http = HTTPRequest.new()\n")
        self.write(os.path.join(self.src, "net", "d.gd"), b'# see BT_LOCAL_PORT\n')
        self.write(os.path.join(self.src, "native.gdns"), b"[gd_resource]\n")
        result = run("--root", self.root, "src")
        self.assertEqual(result.returncode, 1)
        base = "mods/example/src/%s/" % MOD_ID
        self.assertIn("network class in shipped code: %snet/h.gd:1: HTTPRequest" % base,
                      result.stderr)
        self.assertIn("local-play dev mod named in shipped code: %snet/d.gd:1: BT_LOCAL_PORT"
                      % base, result.stderr)
        self.assertIn("native or binary file in shipped code: %snative.gdns" % base, result.stderr)

    def test_dev_code_outside_src_is_not_scanned(self):
        dev = os.path.join(self.root, "mods", "example", "dev")
        os.makedirs(dev)
        self.write(os.path.join(dev, "wire.gd"),
                   b'var peer = NetworkedMultiplayerENet.new()  # BT_LOCAL_PORT\n')
        self.write(os.path.join(dev, "helper.dll"), b"\x00")
        result = run("--root", self.root, "src")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
