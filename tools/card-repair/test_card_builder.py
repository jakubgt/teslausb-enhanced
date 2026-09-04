"""Deployment manifest tests: only reviewed Git blobs, paths and permissions."""

import argparse
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import build_card_repair as builder
import card_install


class CardBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.commit = "1" * 40
        self.baselines = {
            destination: {"allowed_sha256": ["2" * 64], "allow_absent": False}
            for _, destination, _, _ in builder.TARGETS
        }
        for destination in (card_install.DROPIN, "/root/bin/snapshot_lock.sh",
                            "/root/bin/sync-time.py", "/var/www/html/cgi-bin/maintenance.sh",
                            "/var/www/html/cgi-bin/maintenance.py"):
            self.baselines[destination] = {"allowed_sha256": [], "allow_absent": True}
        self.baseline_path = self.root / "baselines.json"
        self.prerequisites_path = self.root / "prerequisites.json"
        self.prerequisites_path.write_text(json.dumps({"/root/bin/unchanged.sh": "3" * 64}), encoding="utf-8")
        self.args = argparse.Namespace(source=self.root / "repo", git="git-test-double",
            commit=self.commit, baselines=self.baseline_path, prerequisites=self.prerequisites_path,
            ssh_module=None, public_key=None, ssh_client_address=None, output=self.root / "package")
        self.blobs = {}
        for source, _, syntax, _ in builder.TARGETS:
            if source:
                self.blobs[source] = ("# " + source + "\n" +
                    ("pass\n" if syntax == "python" else "true\n" if syntax == "bash" else "<html></html>\n")).encode()

    def build(self):
        self.baseline_path.write_text(json.dumps(self.baselines), encoding="utf-8")
        calls = []

        def git_blob(argv):
            self.assertEqual(len(argv), 5)
            self.assertEqual(argv[:4], ["git-test-double", "-C", str(self.args.source), "show"])
            ref, source = argv[4].split(":", 1)
            self.assertEqual(ref, self.commit)
            calls.append(source)
            return self.blobs[source]

        with mock.patch.object(builder.subprocess, "check_output", side_effect=git_blob), \
                contextlib.redirect_stdout(io.StringIO()):
            builder.build(self.args)
        return json.loads((self.args.output / "manifest.json").read_text()), calls

    def test_advanced_panel_exact_targets_permissions_and_syntax(self):
        expected = {
            "/var/www/html/cgi-bin/api-v1.sh": ("teslausb-www/html/cgi-bin/api-v1.sh", "bash", 0o755, False),
            "/var/www/html/cgi-bin/maintenance.sh": ("teslausb-www/html/cgi-bin/maintenance.sh", "bash", 0o755, True),
            "/var/www/html/cgi-bin/maintenance.py": ("teslausb-www/html/cgi-bin/maintenance.py", "python", 0o644, True),
        }
        config, calls = self.build()
        destinations = {item["destination"]: item for item in config["entries"]}
        self.assertEqual(len(calls), len(builder.TARGETS) - 1)
        self.assertEqual(config["source_commit"], self.commit)
        for destination, (source, syntax, mode, absent) in expected.items():
            with self.subTest(destination=destination):
                item = destinations[destination]
                self.assertEqual(item["source"], source)
                self.assertEqual(item["syntax"], syntax)
                self.assertEqual(item["mode"], mode)
                self.assertIs(item["allow_absent"], absent)
                self.assertEqual(item["sha256"], card_install.digest(self.blobs[source]))
                self.assertIn(item["sha256"], item["allowed_sha256"])
        self.assertFalse(any(destination.startswith(("/backingfiles/", "/mutable/TeslaCam/", "/root/.ssh/"))
                             for destination in destinations))

    def test_payload_is_deterministic_and_passes_exact_member_authentication(self):
        config, _ = self.build()
        payload = self.args.output / config["payload_name"]
        initial_payload = payload.read_bytes()
        initial_hook = (self.args.output / "run_once").read_bytes()
        contents = card_install.load_payload(payload, config["payload_sha256"], config["entries"])
        self.assertEqual(set(contents), {item["member"] for item in config["entries"]})
        self.assertEqual(contents["maintenance.py"], self.blobs["teslausb-www/html/cgi-bin/maintenance.py"])
        self.assertEqual(config["prerequisites"], {"/root/bin/unchanged.sh": "3" * 64})
        self.build()
        self.assertEqual(payload.read_bytes(), initial_payload)
        self.assertEqual((self.args.output / "run_once").read_bytes(), initial_hook)

    def test_missing_endpoint_baseline_rejected_before_payload_build(self):
        del self.baselines["/var/www/html/cgi-bin/api-v1.sh"]
        with self.assertRaisesRegex(ValueError, "Baseline destinations"):
            self.build()
        self.assertFalse(self.args.output.exists())

    def test_truthy_string_absence_permission_is_rejected(self):
        self.baselines["/var/www/html/cgi-bin/api-v1.sh"]["allow_absent"] = "false"
        with self.assertRaisesRegex(ValueError, "boolean allow_absent"):
            self.build()
        self.assertFalse(self.args.output.exists())

    def test_new_file_baseline_hash_must_be_valid(self):
        self.baselines["/var/www/html/cgi-bin/maintenance.py"]["allowed_sha256"] = ["not-a-reviewed-sha256"]
        with self.assertRaisesRegex(ValueError, "Malformed baseline"):
            self.build()
        self.assertFalse(self.args.output.exists())

    def test_ambiguous_git_ref_is_not_a_source_pin(self):
        self.args.commit = "main"
        with self.assertRaisesRegex(ValueError, "40-character"):
            self.build()
        self.assertFalse(self.args.output.exists())


if __name__ == "__main__":
    unittest.main()
