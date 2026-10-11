"""Exercise release boundaries with disposable Git repositories and mocked GitHub calls."""
import importlib.util
import json
import gzip
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/release.py"
spec = importlib.util.spec_from_file_location("deckhand_release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="deckhand-release-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "checkout"
        self.root.mkdir()
        self.data = {"version": "0.1.0-beta.1", "build": 1, "repository": "fixture/deckhand"}
        (self.root / "release.json").write_text(json.dumps(self.data))
        (self.root / "docs/releases").mkdir(parents=True)
        (self.root / "docs/releases/0.1.0-beta.1.md").write_text("First beta.\n")
        (self.root / "Scripts").mkdir()
        shutil.copy(SCRIPT, self.root / "Scripts/release.py")
        for name in ["LICENSE", "THIRD_PARTY_NOTICES", "Package.resolved", "Scripts/build-app.sh", "Scripts/build-sqlcipher.sh"]:
            (self.root / name).write_text("Fixture source\n")
        (self.root / ".gitignore").write_text("build/\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.commit()
        origin = Path(self.temporary.name) / "origin.git"
        subprocess.run(["git", "init", "--bare", "-q", str(origin)], check=True)
        self.git("remote", "add", "origin", str(origin))
        self.git("push", "-q", "origin", "HEAD:main")
        self.artifacts = self.root / "build/release"

    def git(self, *args):
        return release.run("git", *args, cwd=self.root)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture commit")

    def tag(self):
        self.git("tag", "-a", "v" + self.data["version"], "-m", "Fixture tag")
        self.git("push", "-q", "origin", "v" + self.data["version"])

    def make_artifacts(self):
        self.artifacts.mkdir(parents=True)
        (self.artifacts / "Deckhand-arm64.dmg").write_bytes(b"Fixture installer")
        with tarfile.open(self.artifacts / "Deckhand-0.1.0-beta.1-source.tar.gz", "w:gz") as archive:
            for name in ["release.json", "LICENSE", "THIRD_PARTY_NOTICES", "Package.resolved", "Scripts/build-app.sh", "Scripts/build-sqlcipher.sh"]:
                archive.add(self.root / name, arcname=name)
        release.write_artifacts(self.artifacts, root=self.root)

    def test_version_order_handles_stable_promotion_and_beta_numbers(self):
        versions = ["0.1.0-beta.1", "0.1.0-beta.2", "0.1.0-beta.10", "0.1.0", "0.1.1-beta.1", "0.1.1", "1.0.0"]
        self.assertEqual(sorted(versions, key=release.version_key), versions)
        for invalid in ["v0.1.0", "0.1", "01.1.0", "0.1.0-beta", "0.1.0-beta.0", "0.1.0;echo bad"]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                release.version_key(invalid)

    def test_prepare_writes_notes_and_increments_build(self):
        notes = Path(self.temporary.name) / "notes.md"
        notes.write_text("Next release\n")
        release.prepare("0.1.0-beta.2", notes, self.root)
        self.assertEqual(release.config(self.root)["build"], 2)
        self.assertEqual(release.config(self.root)["version"], "0.1.0-beta.2")
        self.assertEqual((self.root / "docs/releases/0.1.0-beta.2.md").read_text(), notes.read_text())

    def test_prepare_rejects_dirty_tree_rollback_and_empty_notes(self):
        notes = Path(self.temporary.name) / "notes.md"
        notes.write_text("\n")
        with self.assertRaisesRegex(ValueError, "empty"):
            release.prepare("0.1.0-beta.2", notes, self.root)
        notes.write_text("Notes")
        with self.assertRaisesRegex(ValueError, "newer"):
            release.prepare("0.1.0-beta.1", notes, self.root)
        (self.root / "uncommitted.txt").write_text("Edit")
        with self.assertRaisesRegex(ValueError, "Commit all changes"):
            release.prepare("0.1.0-beta.2", notes, self.root)
        self.assertEqual(release.config(self.root), self.data)

    def test_tag_must_match_version_and_exact_commit(self):
        self.tag()
        release.check(self.root, "v0.1.0-beta.1", True)
        with self.assertRaisesRegex(ValueError, "does not match"):
            release.check(self.root, "v0.9.0")
        (self.root / "LICENSE").write_text("Changed")
        self.commit()
        with self.assertRaisesRegex(ValueError, "checked-out commit"):
            release.check(self.root, "v0.1.0-beta.1")

    def test_release_commit_must_be_merged_on_remote_main(self):
        release.public_commit(self.root)
        (self.root / "LICENSE").write_text("Unmerged change")
        self.commit()
        with self.assertRaisesRegex(ValueError, "origin/main"):
            release.public_commit(self.root)

    def test_cli_creates_annotated_tag_and_pushes_only_to_fixture_remote(self):
        command = ["python3", str(self.root / "Scripts/release.py"), "tag"]
        subprocess.run(command + ["--dry-run"], check=True, capture_output=True)
        self.assertEqual(self.git("tag", "--list"), "")
        subprocess.run(command + ["--push"], check=True, capture_output=True)
        self.assertEqual(self.git("cat-file", "-t", "v0.1.0-beta.1"), "tag")
        self.assertIn("refs/tags/v0.1.0-beta.1", self.git("ls-remote", "origin"))
        repeated = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(repeated.returncode, 0)
        self.assertIn("already exists", repeated.stderr)

    def test_plist_uses_apple_numeric_versions_and_preserves_full_beta(self):
        path = Path(self.temporary.name) / "Info.plist"
        path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "rocks.deckhand.app"}))
        release.stamp_plist(path, self.root)
        info = plistlib.loads(path.read_bytes())
        self.assertEqual(info["CFBundleShortVersionString"], "0.1.0")
        self.assertEqual(info["CFBundleVersion"], "1")
        self.assertEqual(info["DeckhandReleaseVersion"], "0.1.0-beta.1")

    def test_missing_credentials_fail_before_security_or_build(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(release, "run", wraps=release.run) as command:
            with self.assertRaisesRegex(ValueError, "requires DECKHAND_SIGN_IDENTITY"):
                release.preflight(True, self.root)
            self.assertFalse(any(call.args[0] == "security" for call in command.call_args_list))

    def test_artifact_checksums_and_manifest_cover_exact_files(self):
        self.make_artifacts()
        with patch.object(release, "verify_installer") as verify:
            release.validate_artifacts(self.artifacts, root=self.root)
            verify.assert_called_once_with(self.artifacts, False, self.root)
        (self.artifacts / "Deckhand-arm64.dmg").write_bytes(b"Corrupted")
        with self.assertRaisesRegex(ValueError, "checksum"):
            release.validate_artifacts(self.artifacts, root=self.root)

    def test_duplicate_or_path_traversal_checksum_entries_are_rejected(self):
        self.make_artifacts()
        checks = self.artifacts / "SHA256SUMS.txt"
        original = checks.read_text()
        for extra in [original.splitlines()[0], "0" * 64 + "  ../../release.json"]:
            checks.write_text(original + extra + "\n")
            with self.assertRaisesRegex(ValueError, "Invalid checksum or asset"):
                release.validate_artifacts(self.artifacts, root=self.root)

    def test_source_archive_and_notes_must_match_release(self):
        self.make_artifacts()
        (self.root / "release.json").write_text(json.dumps({**self.data, "build": 2}))
        release.write_artifacts(self.artifacts, root=self.root)
        with self.assertRaisesRegex(ValueError, "Source archive"):
            release.validate_artifacts(self.artifacts, root=self.root)

    def test_modified_release_notes_are_rejected_even_with_valid_checksums(self):
        self.make_artifacts()
        (self.root / "docs/releases/0.1.0-beta.1.md").write_text("Different notes")
        with self.assertRaisesRegex(ValueError, "notes do not match"):
            release.validate_artifacts(self.artifacts, root=self.root)

    def test_preview_cannot_pass_public_validation(self):
        self.make_artifacts()
        self.tag()
        with self.assertRaisesRegex(ValueError, "must be notarized"):
            release.validate_artifacts(self.artifacts, True, self.root)

    def test_public_source_is_exactly_the_committed_tree(self):
        source = Path(self.temporary.name) / "source.tar.gz"
        committed = subprocess.check_output(["git", "archive", "--format=tar", "HEAD"], cwd=self.root)
        source.write_bytes(gzip.compress(committed))
        release.verify_source_commit(source, self.root)
        (self.root / "LICENSE").write_text("Changed source")
        self.commit()
        with self.assertRaisesRegex(ValueError, "exactly git archive"):
            release.verify_source_commit(source, self.root)

    def publish_fixture(self, uploaded_override=None, existing=False):
        self.make_artifacts()
        self.tag()
        assets = [{"name": path.name, "size": path.stat().st_size, "digest": "sha256:" + release.digest(path)}
                  for path in self.artifacts.iterdir()]
        self.uploaded = {"draft": True, "assets": assets}
        if uploaded_override: uploaded_override(self.uploaded)
        self.commands = []
        original_run = release.run

        def command(*args, cwd=None):
            self.commands.append(args)
            return "" if args[0] == "gh" else original_run(*args, cwd=cwd)

        return (patch.object(release, "validate_artifacts", return_value=self.data),
                patch.object(release, "github_release", side_effect=[{"draft": False} if existing else None, self.uploaded]),
                patch.object(release, "run", side_effect=command))

    def test_publish_uploads_to_draft_then_sets_beta_without_latest(self):
        validation, lookup, commands = self.publish_fixture()
        with validation as checked, lookup, commands:
            release.publish(self.artifacts, self.root)
            checked.assert_called_once_with(self.artifacts, public=True, root=self.root)
        actions = [args[2] for args in self.commands if args[0] == "gh"]
        self.assertEqual(actions, ["create", "upload", "edit"])
        final = self.commands[-1]
        self.assertIn("--prerelease=true", final)
        self.assertIn("--latest=false", final)

    def test_missing_or_bad_remote_asset_leaves_release_as_draft(self):
        def corrupt(uploaded): uploaded["assets"][0]["digest"] = "sha256:wrong"
        validation, lookup, commands = self.publish_fixture(corrupt)
        with validation, lookup, commands, self.assertRaisesRegex(ValueError, "verification failed"):
            release.publish(self.artifacts, self.root)
        self.assertFalse(any(args[:3] == ("gh", "release", "edit") for args in self.commands))

    def test_published_release_is_never_overwritten(self):
        validation, lookup, commands = self.publish_fixture(existing=True)
        with validation, lookup, commands, self.assertRaisesRegex(ValueError, "already published"):
            release.publish(self.artifacts, self.root)
        self.assertFalse(any(args[0] == "gh" for args in self.commands))

    def test_draft_retry_uploads_without_creating_another_release(self):
        validation, _, commands = self.publish_fixture()
        with validation, patch.object(release, "github_release", side_effect=[{"draft": True}, self.uploaded]), commands:
            release.publish(self.artifacts, self.root)
        self.assertEqual([args[2] for args in self.commands if args[0] == "gh"], ["upload", "edit"])

    def test_draft_lookup_uses_authenticated_list_then_id_not_published_tag_endpoint(self):
        draft = {"id": 12, "tag_name": "v0.1.0-beta.1", "draft": True, "assets": []}
        with patch.object(release, "run", side_effect=[json.dumps([[draft]]), json.dumps(draft)]) as command:
            self.assertEqual(release.github_release("fixture/deckhand", draft["tag_name"]), draft)
        self.assertEqual(command.call_args_list[0].args, ("gh", "api", "--paginate", "--slurp", "repos/fixture/deckhand/releases?per_page=100"))
        self.assertEqual(command.call_args_list[1].args, ("gh", "api", "repos/fixture/deckhand/releases/12"))
        with patch.object(release, "run", return_value="[[]]"):
            self.assertIsNone(release.github_release("fixture/deckhand", "missing"))
        with patch.object(release, "run", return_value=json.dumps([[draft, draft]])), self.assertRaisesRegex(ValueError, "Multiple releases"):
            release.github_release("fixture/deckhand", draft["tag_name"])

    def test_stable_release_promotes_latest_and_rejects_rollback(self):
        validation, lookup, commands = self.publish_fixture()
        self.data["version"] = "0.1.0"
        (self.artifacts / "Deckhand-0.1.0-beta.1-source.tar.gz").rename(self.artifacts / "Deckhand-0.1.0-source.tar.gz")
        for asset in self.uploaded["assets"]:
            if asset["name"] == "Deckhand-0.1.0-beta.1-source.tar.gz":
                asset["name"] = "Deckhand-0.1.0-source.tar.gz"
        self.git("tag", "v0.1.0")
        self.git("push", "-q", "origin", "v0.1.0")
        # The validator is mocked here; real clean-tag/source/Gatekeeper validation is
        # independently covered. This test exercises promotion and rollback decisions.
        latest = subprocess.CompletedProcess([], 0, json.dumps({"tag_name": "v0.0.9"}), "")

        def decision_command(*args, **kwargs):
            if args[:2] == ("git", "rev-parse"): return "fixture"
            if args[:2] == ("git", "ls-remote"): return "fixture\trefs/tags/v0.1.0"
            self.commands.append(args)
            return ""

        with validation, lookup, patch.object(release.subprocess, "run", return_value=latest), patch.object(release, "run", side_effect=decision_command):
            release.publish(self.artifacts, self.root)
        self.assertIn("--latest=true", self.commands[-1])
        self.assertIn("--prerelease=false", self.commands[-1])
        self.commands.clear()
        latest.stdout = json.dumps({"tag_name": "v0.2.0"})
        with patch.object(release, "validate_artifacts", return_value=self.data), patch.object(release, "github_release", return_value=None), patch.object(release.subprocess, "run", return_value=latest), patch.object(release, "run", side_effect=decision_command):
            with self.assertRaisesRegex(ValueError, "older or equal"):
                release.publish(self.artifacts, self.root)
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main()
