#!/usr/bin/env python3
"""Version, validate, tag and publish Deckhand releases. No third-party Python packages."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-beta\.([1-9]\d*))?")


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd or ROOT, text=True, stderr=subprocess.PIPE).strip()


def version_key(version):
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError("Use X.Y.Z or X.Y.Z-beta.N (for example 0.1.0-beta.1)")
    major, minor, patch, beta = match.groups()
    return (int(major), int(minor), int(patch), 1 if beta is None else 0, int(beta or 0))


def config(root=ROOT):
    data = json.loads((root / "release.json").read_text())
    version_key(data["version"])
    if type(data["build"]) is not int or data["build"] < 1:
        raise ValueError("release.json build must be a positive integer")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", data["repository"]):
        raise ValueError("Invalid release repository")
    return data


def clean(root=ROOT):
    if run("git", "status", "--porcelain", cwd=root):
        raise ValueError("Commit all changes before tagging or publishing a release")


def check(root=ROOT, tag=None, require_clean=False):
    data = config(root)
    notes = root / "docs/releases" / (data["version"] + ".md")
    if not notes.is_file() or not notes.read_text().strip():
        raise ValueError(f"Missing release notes: {notes}")
    if tag:
        if tag != "v" + data["version"]:
            raise ValueError(f"Tag {tag} does not match release.json v{data['version']}")
        if run("git", "rev-parse", tag + "^{commit}", cwd=root) != run("git", "rev-parse", "HEAD", cwd=root):
            raise ValueError("The release tag must point to the checked-out commit")
    if require_clean:
        clean(root)
    return data


def prepare(version, notes_file, root=ROOT):
    clean(root)
    data = config(root)
    if version_key(version) <= version_key(data["version"]):
        raise ValueError("The new version must be newer than the current version")
    notes = notes_file.read_text()
    if not notes.strip():
        raise ValueError("Release notes cannot be empty")
    target = root / "docs/releases" / (version + ".md")
    if target.exists() or run("git", "tag", "--list", "v" + version, cwd=root):
        raise ValueError("That release already exists; choose a new version")
    data.update(version=version, build=data["build"] + 1)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(notes)
    try:
        temporary = root / "release.json.tmp"
        temporary.write_text(json.dumps(data, indent=2) + "\n")
        temporary.replace(root / "release.json")
    except OSError:
        target.unlink()
        raise
    print(f"Prepared v{version}, build {data['build']}. Review and commit release.json and {target.relative_to(root)}.")


def preflight(public=False, root=ROOT):
    data = check(root)
    if public:
        clean(root)
        identity = os.environ.get("DECKHAND_SIGN_IDENTITY", "")
        profile = os.environ.get("DECKHAND_NOTARY_PROFILE", "")
        if not identity.startswith("Developer ID Application:") or not profile:
            raise ValueError("Public release requires DECKHAND_SIGN_IDENTITY (Developer ID Application) and DECKHAND_NOTARY_PROFILE")
        if identity not in run("security", "find-identity", "-v", "-p", "codesigning", "-s", identity):
            raise ValueError("The requested Developer ID identity is not installed in the keychain")
    return data


def stamp_plist(path, root=ROOT):
    data = config(root)
    with path.open("rb") as source:
        info = plistlib.load(source)
    info.update(CFBundleShortVersionString=data["version"].split("-")[0],
                CFBundleVersion=str(data["build"]), DeckhandReleaseVersion=data["version"])
    with path.open("wb") as dest:
        plistlib.dump(info, dest)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def verify_installer(directory, public=False, root=ROOT):
    # Assess the actual installed app rather than trusting manifest metadata.
    with tempfile.TemporaryDirectory(prefix="deckhand-installer-") as temporary:
        mount = Path(temporary) / "Disk Image"
        run("hdiutil", "attach", str(directory / "Deckhand-arm64.dmg"), "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount))
        try:
            if not (mount / "Applications").is_symlink() or (mount / "Applications").readlink() != Path("/Applications"):
                raise ValueError("The installer must include the Applications shortcut")
            args = [sys.executable, str(root / "Scripts/verify-app.py"), str(mount / "Deckhand.app")]
            if public: args.append("--public")
            print(run(*args, cwd=root))
        finally:
            run("hdiutil", "detach", str(mount))


def write_artifacts(directory, public=False, root=ROOT):
    data = check(root)
    names = ["Deckhand-arm64.dmg", f"Deckhand-{data['version']}-source.tar.gz"]
    manifest = {**data, "commit": run("git", "rev-parse", "HEAD", cwd=root),
                "dirty": bool(run("git", "status", "--porcelain", cwd=root)),
                "distribution": "notarized" if public else "local-preview",
                "minimumOS": "26.0", "architecture": "arm64",
                "assets": {name: digest(directory / name) for name in names}}
    (directory / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (directory / "release-notes.md").write_text((root / "docs/releases" / (data["version"] + ".md")).read_text())
    names += ["release-manifest.json", "release-notes.md"]
    (directory / "SHA256SUMS.txt").write_text("".join(f"{digest(directory / name)}  {name}\n" for name in names))


def validate_artifacts(directory, public=False, root=ROOT):
    data = check(root)
    expected = {"Deckhand-arm64.dmg", f"Deckhand-{data['version']}-source.tar.gz",
                "release-manifest.json", "release-notes.md"}
    seen = set()
    for line in (directory / "SHA256SUMS.txt").read_text().splitlines():
        value, name = line.split("  ", 1)
        if name not in expected or name in seen or value != digest(directory / name):
            raise ValueError(f"Invalid checksum or asset: {name}")
        seen.add(name)
    if seen != expected:
        raise ValueError("Release checksums must cover every expected asset")
    manifest = json.loads((directory / "release-manifest.json").read_text())
    if any(manifest[key] != data[key] for key in ["version", "build", "repository"]):
        raise ValueError("Artifacts do not match release.json")
    if manifest["architecture"] != "arm64" or manifest["minimumOS"] != "26.0":
        raise ValueError("Unexpected release platform")
    if set(manifest["assets"]) != {"Deckhand-arm64.dmg", f"Deckhand-{data['version']}-source.tar.gz"}:
        raise ValueError("Unexpected manifest assets")
    for name, value in manifest["assets"].items():
        if value != digest(directory / name):
            raise ValueError(f"Manifest checksum mismatch: {name}")
    with tarfile.open(directory / f"Deckhand-{data['version']}-source.tar.gz") as archive:
        member = archive.extractfile("release.json")
        if member is None or json.load(member) != data:
            raise ValueError("Source archive does not match the release version")
        names = set(archive.getnames())
        for required in ["LICENSE", "THIRD_PARTY_NOTICES", "Package.resolved", "Scripts/build-app.sh", "Scripts/build-sqlcipher.sh"]:
            if required not in names:
                raise ValueError(f"Source archive missing {required}")
    if (directory / "release-notes.md").read_text() != (root / "docs/releases" / (data["version"] + ".md")).read_text():
        raise ValueError("Release notes do not match the tagged source")
    if public:
        check(root, tag="v" + data["version"], require_clean=True)
        if manifest["distribution"] != "notarized" or manifest["dirty"] or manifest["commit"] != run("git", "rev-parse", "HEAD", cwd=root):
            raise ValueError("Public artifacts must be notarized and built from this clean tagged commit")
        run("xcrun", "stapler", "validate", str(directory / "Deckhand-arm64.dmg"))
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(directory / "Deckhand-arm64.dmg"))
    verify_installer(directory, public, root)
    return data


def github_release(repo, tag):
    result = subprocess.run(["gh", "api", f"repos/{repo}/releases/tags/{tag}"], text=True, capture_output=True)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "HTTP 404" in result.stderr:
        return None
    raise ValueError("GitHub release lookup failed: " + result.stderr.strip())


def publish(directory, root=ROOT):
    data = validate_artifacts(directory, public=True, root=root)
    repo, tag = data["repository"], "v" + data["version"]
    head = run("git", "rev-parse", "HEAD", cwd=root)
    remote = run("git", "ls-remote", "origin", "refs/tags/" + tag, "refs/tags/" + tag + "^{}", cwd=root)
    if not any(line.split()[0] == head for line in remote.splitlines()):
        raise ValueError("Push the tag to origin before publishing")
    # A retry must never mutate a published release or roll the stable channel backwards.
    existing = github_release(repo, tag)
    if existing and not existing["draft"]:
        raise ValueError("This release is already published; published versions cannot be replaced")
    beta = "-beta." in data["version"]
    if not beta:
        result = subprocess.run(["gh", "api", f"repos/{repo}/releases/latest"], text=True, capture_output=True)
        if result.returncode == 0:
            latest = json.loads(result.stdout)
            if version_key(latest["tag_name"].removeprefix("v")) >= version_key(data["version"]):
                raise ValueError("Refusing to replace the stable download with an older or equal version")
        elif "HTTP 404" not in result.stderr:
            raise ValueError("Could not check the current stable release")
    if existing is None:
        run("gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--draft", "--title", f"Deckhand {data['version']}",
            "--notes-file", str(directory / "release-notes.md"), cwd=root)
    assets = ["Deckhand-arm64.dmg", f"Deckhand-{data['version']}-source.tar.gz", "release-manifest.json", "release-notes.md", "SHA256SUMS.txt"]
    run("gh", "release", "upload", tag, "--repo", repo, *[str(directory / name) for name in assets], "--clobber", cwd=root)
    uploaded = github_release(repo, tag)
    remote_assets = {asset["name"]: asset for asset in uploaded["assets"]}
    if set(remote_assets) != set(assets):
        raise ValueError("Draft release has unexpected or missing assets; it remains unpublished")
    for name in assets:
        asset = remote_assets[name]
        if asset["size"] != (directory / name).stat().st_size or asset.get("digest") != "sha256:" + digest(directory / name):
            raise ValueError(f"Uploaded asset verification failed: {name}; the release remains a draft")
    run("gh", "release", "edit", tag, "--repo", repo, "--draft=false", f"--prerelease={'true' if beta else 'false'}",
        f"--latest={'false' if beta else 'true'}", "--notes-file", str(directory / "release-notes.md"), cwd=root)
    print(f"Published https://github.com/{repo}/releases/tag/{tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    value = sub.add_parser("value"); value.add_argument("field", choices=["version", "build", "tag", "marketing", "repository"])
    prep = sub.add_parser("prepare"); prep.add_argument("version"); prep.add_argument("--notes-file", type=Path, required=True)
    verify = sub.add_parser("check"); verify.add_argument("--tag"); verify.add_argument("--require-clean", action="store_true")
    pre = sub.add_parser("preflight"); pre.add_argument("--public", action="store_true")
    stamp = sub.add_parser("stamp-plist"); stamp.add_argument("path", type=Path)
    tag = sub.add_parser("tag"); tag.add_argument("--push", action="store_true"); tag.add_argument("--dry-run", action="store_true")
    for command in ["manifest", "validate-artifacts", "publish"]:
        item = sub.add_parser(command); item.add_argument("--artifacts", type=Path, default=ROOT / "build/release")
        if command != "publish": item.add_argument("--public", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "value":
            data = config()
            print({**data, "tag": "v" + data["version"], "marketing": data["version"].split("-")[0]}[args.field])
        elif args.command == "prepare": prepare(args.version, args.notes_file)
        elif args.command == "check": check(tag=args.tag, require_clean=args.require_clean); print("Release version and notes verified")
        elif args.command == "preflight": preflight(args.public); print("Release preflight passed")
        elif args.command == "stamp-plist": stamp_plist(args.path)
        elif args.command == "tag":
            data = check(require_clean=True); name = "v" + data["version"]
            if run("git", "tag", "--list", name): raise ValueError("This tag already exists; choose a new version or rerun its workflow")
            if args.dry_run: print(f"Would create annotated tag {name} at {run('git', 'rev-parse', 'HEAD')}")
            else:
                run("git", "tag", "-a", name, "-F", str(ROOT / "docs/releases" / (data["version"] + ".md")))
                if args.push: run("git", "push", "origin", name)
                print("Created " + name)
        elif args.command == "manifest": write_artifacts(args.artifacts, args.public)
        elif args.command == "validate-artifacts": validate_artifacts(args.artifacts, args.public); print("Release artifacts verified")
        elif args.command == "publish": publish(args.artifacts)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        message = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(1, f"Release failed: {message}\n")


if __name__ == "__main__":
    main()
