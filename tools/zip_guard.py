#!/usr/bin/env python3
"""Checks that only the mods themselves ship, and that shipped code opens no network way in.

1. zips: every .zip under the dist folder (tools/package.sh writes <dist>/<Name>/<Name>.zip) holds
   the folder mods-unpacked/ and one mod folder in it, mods-unpacked/<mod_id>/ with its
   manifest.json, where <mod_id> is a mod of this repo (mods/*/src/<mod_id>/manifest.json).
   Anything else (a file at the root, a second folder such as a dev mod, "..", an absolute path)
   is an error. The dist folder must hold at least one zip.
2. Network classes: no file in a zip, and no file in mods/*/src/, names one of NETWORK_CLASSES
   (sockets, HTTP, TLS / DTLS, WebRTC, UPnP). The mods talk through Steam only (GodotSteam);
   such a class in shipped code would be a second way in. Dev tools that need sockets live
   outside src/ and never reach a zip.
3. Native and binary code: no file in a zip, and no file in mods/*/src/, ends in one of
   NATIVE_SUFFIXES (libraries, GDNative, packs, compiled scripts, programs). Shipped code is
   GDScript and data anyone can read.
4. The local-play dev mod: no file in a zip, and no file in mods/*/src/, names it or its
   environment (DEV_MARKERS: einfluffles-TogetherLocal, BT_LOCAL_*). Shipped code knows nothing
   of it; the dev mod reaches the mod through Transport.bind_steam only.

Usage: tools/zip_guard.py [--root DIR] src          (run by tools/lint.sh)
       tools/zip_guard.py [--root DIR] zips DIST    (run by .github/workflows/build.yml)
--root is the repo (default: this script's parent folder). Tests: tools/test_zip_guard.py.
"""
import argparse
import pathlib
import re
import sys
import zipfile

NETWORK_CLASSES = (
    "NetworkedMultiplayerENet",
    "PacketPeerUDP",
    "StreamPeerTCP",
    "TCP_Server",
    "UDPServer",
    r"WebSocket\w*",  # WebSocketServer, WebSocketClient, WebSocketMultiplayerPeer, ...
    "HTTPRequest",
    "HTTPClient",
    "StreamPeerSSL",
    "PacketPeerDTLS",
    "DTLSServer",
    r"WebRTC\w*",  # WebRTCPeerConnection, WebRTCDataChannel, WebRTCMultiplayer, ...
    r"UPNP(?:Device)?",
)
NETWORK = re.compile(r"\b(?:%s)\b" % "|".join(NETWORK_CLASSES))
NATIVE_SUFFIXES = (".dll", ".so", ".dylib", ".gdnlib", ".gdns", ".pck", ".gdc", ".exe")
# The suffix at the end of the name, also before a version (libx.so.1).
NATIVE = re.compile(r"(?:%s)(?:\.\d+)*$" % "|".join(re.escape(s) for s in NATIVE_SUFFIXES),
                    re.IGNORECASE)
DEV_MARKERS = re.compile(r"einfluffles-TogetherLocal|BT_LOCAL_\w*")
ROOT_FOLDER = "mods-unpacked/"


def mod_ids(root):
    return sorted(p.parent.name for p in root.glob("mods/*/src/*/manifest.json"))


def file_errors(name, data):
    """What a shipped file must not be or hold: a native suffix, and '<name>:<line>: <word>' for
    every network class and dev-mod marker in its bytes (decoded leniently)."""
    errors = []
    if NATIVE.search(name):
        errors.append("native or binary file in shipped code: %s" % name)
    text = data.decode("utf-8", errors="replace")
    for number, line in enumerate(text.splitlines(), 1):
        for match in NETWORK.finditer(line):
            errors.append("network class in shipped code: %s:%d: %s"
                          % (name, number, match.group(0)))
        for match in DEV_MARKERS.finditer(line):
            errors.append("local-play dev mod named in shipped code: %s:%d: %s"
                          % (name, number, match.group(0)))
    return errors


def check_src(root):
    errors = []
    for path in sorted(root.glob("mods/*/src/**/*")):
        if path.is_file():
            errors += file_errors(path.relative_to(root).as_posix(), path.read_bytes())
    return errors


def check_zip(path, known_ids):
    errors = []
    label = path.name
    try:
        archive = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        return ["%s: not a zip (%s)" % (label, e)]
    with archive:
        folders = set()
        names = archive.namelist()
        for name in names:
            parts = name.split("/")
            bad = (name.startswith("/") or "\\" in name or ".." in parts
                   or re.match(r"^[A-Za-z]:", name) is not None)
            if bad:
                errors.append("%s: unsafe path %r" % (label, name))
                continue
            if name == ROOT_FOLDER:
                continue
            if not name.startswith(ROOT_FOLDER) or len(parts) < 3 or parts[1] == "":
                errors.append("%s: %r is outside mods-unpacked/<mod_id>/" % (label, name))
                continue
            folders.add(parts[1])
        for folder in sorted(folders - set(known_ids)):
            errors.append("%s: mods-unpacked/%s/ is no mod of this repo (mods/*/src/<mod_id>/)"
                          % (label, folder))
        if len(folders) != 1:
            errors.append("%s: %d mod folders in mods-unpacked/ (%s), expected one"
                          % (label, len(folders), ", ".join(sorted(folders)) or "none"))
        for folder in sorted(folders & set(known_ids)):
            if "%s%s/manifest.json" % (ROOT_FOLDER, folder) not in names:
                errors.append("%s: mods-unpacked/%s/manifest.json missing" % (label, folder))
        for info in archive.infolist():
            if not info.is_dir():
                errors += ["%s: %s" % (label, error)
                           for error in file_errors(info.filename, archive.read(info))]
    return errors


def check_zips(dist, root):
    zips = sorted(dist.rglob("*.zip"))
    if not zips:
        return ["no .zip under %s" % dist]
    known = mod_ids(root)
    errors = []
    for path in zips:
        errors += check_zip(path, known)
    if not errors:
        for path in zips:
            print("  ok   %s" % path.relative_to(dist).as_posix())
    return errors


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parent.parent)
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("src")
    zips = sub.add_parser("zips")
    zips.add_argument("dist", type=pathlib.Path)
    args = parser.parse_args(argv)
    if args.mode == "src":
        errors = check_src(args.root)
    else:
        errors = check_zips(args.dist, args.root)
    for error in errors:
        print("zip_guard: " + error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
