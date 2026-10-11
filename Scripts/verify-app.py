#!/usr/bin/env python3
"""Reject external runtime dependencies and exercise the packaged database/model."""
import argparse
import pathlib
import plistlib
import subprocess
import json


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def verify(app, public=False):
    app = app.resolve()
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info["LSMinimumSystemVersion"] != "26.0":
        raise ValueError("Release minimum OS must be macOS 26.0")
    release = json.loads((pathlib.Path(__file__).resolve().parent.parent / "release.json").read_text())
    expected = {"CFBundleIdentifier": "rocks.deckhand.app", "CFBundleVersion": str(release["build"]),
                "CFBundleShortVersionString": release["version"].split("-")[0], "DeckhandReleaseVersion": release["version"]}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"App metadata {key} must match release.json: {value}")
    for name in ["DeckhandApp", "deckhand"]:
        binary = app / "Contents/MacOS" / name
        if run("lipo", "-archs", str(binary)).strip() != "arm64":
            raise ValueError(f"Expected an Apple Silicon executable: {name}")
        for line in run("otool", "-L", str(binary)).splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if not dependency.startswith(("/System/Library/", "/usr/lib/")):
                raise ValueError(f"External runtime dependency in {name}: {dependency}")
        commands = run("otool", "-l", str(binary)).splitlines()
        for index, line in enumerate(commands):
            if line.strip() == "cmd LC_RPATH":
                search_path = commands[index + 2].strip().removeprefix("path ").split(" (", 1)[0]
                if search_path.startswith(("/opt/homebrew", "/usr/local", "/Users/")):
                    raise ValueError(f"Developer library search path in {name}: {search_path}")
    resources = app / "Contents/Resources"
    for required in ["Deckhand_Analysis.bundle/SKeyChromaNet.mlmodelc/metadata.json",
                     "Licenses/LICENSE", "Licenses/THIRD_PARTY_NOTICES", "Licenses/SQLCipher.txt",
                     "Licenses/libKeyFinder.txt", "Licenses/qm-dsp.txt", "Licenses/KISS-FFT.txt",
                     "Licenses/Swift-Argument-Parser.txt"]:
        if not (resources / required).is_file():
            raise ValueError(f"Missing bundled resource: {required}")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    if public:
        for target in [app, app / "Contents/MacOS/deckhand"]:
            signature = run("codesign", "--display", "--verbose=4", str(target))
            if "Authority=Developer ID Application:" not in signature or "runtime" not in signature:
                raise ValueError("Public executables must be Developer ID signed with hardened runtime")
        run("xcrun", "stapler", "validate", str(app))
        run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
    print(run(str(app / "Contents/MacOS/deckhand"), "debug", "runtime-check"), end="")
    print("Standalone bundle verified: arm64, macOS 26+, system libraries only")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--public", action="store_true", help="Require Developer ID, hardened runtime, stapled ticket and Gatekeeper acceptance")
    arguments = parser.parse_args()
    try:
        verify(arguments.app, arguments.public)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Bundle verification failed: {error}\n")
