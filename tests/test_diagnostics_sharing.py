"""Bounded, best-effort diagnostic sharing without changing the private report."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


CGI_DIR = Path(__file__).resolve().parents[1] / "teslausb-www/html/cgi-bin"
SPEC = importlib.util.spec_from_file_location("sharing_maintenance", CGI_DIR / "maintenance.py")
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)


def response_data(raw):
    head, body = raw.split(b"\r\n\r\n", 1)
    headers = dict(line.split(": ", 1) for line in head.decode("ascii").split("\r\n"))
    return headers, json.loads(body)


class RedactionTests(unittest.TestCase):
    def prepare(self, text, **options):
        return maintenance.redact_diagnostics(text.encode("utf-8"), **options)

    def test_quoted_json_shell_and_custom_secret_assignments_hide_complete_line(self):
        secrets = (
            "MY_CUSTOM_SECRET='a complicated secret; keep all of it'",
            'export wifi_PsK="not a single word"',
            '{"username":"personal-user","password":"private-password","ok":true}',
            "CIFS_PASSWORD=space separated credential # with a comment",
            'ESSID:"Private WiFi"  Link Quality=70/70',
            "Archive password for mount: secret value here",
            'Authorization: Bearer abc.def.ghi',
            "Cookie: session=private-session",
            "VIN: 5YJ3E1EA4KF000001",
        )
        for secret in secrets:
            with self.subTest(secret=secret):
                result = self.prepare(secret + "\nError: archive timed out\n")
                self.assertNotIn(secret, result["text"])
                self.assertIn("[REDACTED SENSITIVE LINE]", result["text"])
                self.assertIn("Error: archive timed out", result["text"])
                self.assertGreater(result["redactions"]["credentials"], 0)

    def test_password_arguments_are_not_only_masked_to_first_space(self):
        commands = (
            "rclone copy remote: /archive --password 'several secret words' --quiet",
            "curl -u 'person:multi word password' https://archive.example/api",
            "sshpass -p 'several secret words' ssh nas",
            "smbclient -U user%password //nas/share",
            "tool --api-token=private --another-option innocuous",
        )
        for command in commands:
            with self.subTest(command=command):
                result = self.prepare(command)
                self.assertNotIn(command, result["text"])
                self.assertEqual(result["redactions"]["credentials"], 1)

    def test_multiline_quotes_shell_continuations_and_yaml_blocks(self):
        text = (
            'PASSWORD="first private line\nsecond private line\nlast private line"\n'
            "PRIVATE_TOKEN=first \\\nsecond \\\nlast\n"
            "client_secret: |\n  private block first\n  private block second\n"
            "Storage free: 28 GiB\n"
        )
        result = self.prepare(text)
        for secret in ("first private", "second private", "last private", "private block", "second \\", "last\n"):
            self.assertNotIn(secret, result["text"])
        self.assertIn("Storage free: 28 GiB", result["text"])
        self.assertGreater(result["redactions"]["credentials"], 6)

    def test_private_key_blocks_including_unterminated_and_truncated_material(self):
        for label in ("OPENSSH PRIVATE KEY", "RSA PRIVATE KEY", "PRIVATE KEY", "CERTIFICATE"):
            text = ("====== summary ======\n-----BEGIN " + label + "-----\n"
                    "personal key material here\n-----END " + label + "-----\nCPU: 49 C\n")
            result = self.prepare(text)
            self.assertNotIn("personal key material", result["text"])
            self.assertIn("CPU: 49 C", result["text"])
            self.assertEqual(result["redactions"]["private_keys"], 3)
        result = self.prepare("-----BEGIN PRIVATE KEY-----\nsecret until end of capture\n")
        self.assertNotIn("secret until", result["text"])
        for text in ("A" * 64, "ssh-ed25519 " + "B" * 60 + " private-comment"):
            self.assertNotIn(text, self.prepare(text)["text"])

    def test_truncated_capture_discards_unknown_context_until_complete_section(self):
        text = ("partial very private value\ncontinuation without a label\n"
                "====== network ======\n192.168.1.25 connected\n")
        result = self.prepare(text, truncated=True)
        self.assertNotIn("private value", result["text"])
        self.assertNotIn("without a label", result["text"])
        self.assertIn("====== network ======", result["text"])
        self.assertNotIn("192.168.1.25", result["text"])
        result = self.prepare("unknown secret continuation\nmore secret\n", truncated=True)
        self.assertNotIn("more secret", result["text"])
        self.assertIn("no complete diagnostic section", result["text"])
        self.assertEqual(result["redactions"]["truncated_context"], 1)

    def test_empty_assignment_hides_next_value_even_without_indentation(self):
        for prefix, value in (('"token":', '"bare private value"'),
                              ("password=", "unindented-private-value"),
                              ("client_secret:", '"first private line\nlast private line"')):
            with self.subTest(prefix=prefix):
                result = self.prepare(prefix + "\n" + value + "\nCPU: 49 C\n")
                for fragment in value.replace('"', "").splitlines():
                    self.assertNotIn(fragment, result["text"])
                self.assertIn("CPU: 49 C", result["text"])

    def test_overlong_sensitive_line_cannot_expose_unlabelled_continuation(self):
        text = ('PASSWORD="' + "x" * maintenance.MAX_SHARED_LINE_CHARS +
                '\nbare private value\nclosing private value"\n'
                '====== network ======\nCPU: 49 C\n')
        result = self.prepare(text)
        self.assertNotIn("bare private", result["text"])
        self.assertNotIn("closing private", result["text"])
        self.assertIn("CPU: 49 C", result["text"])

    def test_sensitive_objects_and_arrays_are_redacted_without_indent_assumptions(self):
        for prefix in ('"credentials":\n', 'custom_secret='):
            text = (prefix + '{\n"customname":"private-value",\n'
                    '"list":[\n"private-array-value"\n]\n}\nCPU: 49 C\n')
            result = self.prepare(text)
            self.assertNotIn("private-value", result["text"])
            self.assertNotIn("private-array-value", result["text"])
            self.assertIn("CPU: 49 C", result["text"])

    def test_network_identifiers_and_user_paths_are_removed(self):
        text = (
            "archive https://person:encoded%20password@my-nas.example:8443/private?token=secret\n"
            "mounted //personal-nas/PrivateShare at /archive\n"
            "inet 192.168.1.219 netmask 255.255.255.0\n"
            "inet6 fe80::1234:abcd%wlan0\n"
            "ether aa:bb:cc:dd:ee:ff\n"
            "ether aa-bb-cc-dd-ee-ff\n"
            "filesystem 01234567-89ab-cdef-0123-456789abcdef\n"
            "support person@example.com\n"
            "read /home/personal-user/private/file.txt and C:\\Users\\Personal\\secret.log\n"
            "5YJ3E1EA4KF000001\n"
            "Nov 13 12:33:04 private-host archiveloop[123]: ready\n"
            "private-host has been up 2 hours. System time is Thu Nov 13\n"
        )
        result = self.prepare(text)
        for secret in ("person:", "encoded%20", "my-nas.example", "personal-nas", "PrivateShare",
                       "192.168.1.219", "255.255.255.0", "fe80::", "aa:bb:cc:dd:ee:ff",
                       "aa-bb-cc-dd-ee-ff", "01234567-89ab-cdef-0123-456789abcdef",
                       "person@example", "personal-user", "Personal", "5YJ3E1EA4KF000001", "private-host"):
            self.assertNotIn(secret, result["text"])
        self.assertIn("archiveloop[123]: ready", result["text"])
        self.assertIn("has been up 2 hours", result["text"])

    def test_process_arguments_and_known_unlabelled_tokens_removed(self):
        tokens = ("ghp_" + "a" * 36, "github_pat_" + "b" * 45,
                  "Bearer abcdefghi", "eyJabcdef.abcdefghi.abcdefghi")
        text = "root 123 1 0 12:00 ? 00:00:00 tool positional-secret\n" + "\n".join(tokens)
        result = self.prepare(text)
        self.assertNotIn("positional-secret", result["text"])
        for token in tokens:
            self.assertNotIn(token, result["text"])
        self.assertEqual(result["redactions"]["processes"], 1)

    def test_nfs_and_sshfs_mount_sources_hide_host_and_share_only(self):
        text = (
            "private-nas:/PrivateFamily/Tesla /mnt/archive nfs rw,vers=4 0 0\n"
            "private-nas:/PrivateFamily/Tesla on /mnt/archive type nfs4 (rw,relatime)\n"
            "[fe80::1234%wlan0]:/PrivateFamily /mnt/nfs nfs4 rw 0 0\n"
            "personal-user@nas.local:/PrivateFamily /mnt/sshfs fuse.sshfs rw 0 0\n"
            "/dev/mmcblk0p3 /backingfiles xfs rw,noatime 0 0\n"
            "/dev/loop0 /mnt/cam vfat ro 0 0\n"
            "/etc/fstab was checked; C:/Windows/system32 is a local path\n"
        )
        result = self.prepare(text)
        for private in ("private-nas", "PrivateFamily", "fe80::1234", "personal-user", "nas.local"):
            self.assertNotIn(private, result["text"])
        self.assertEqual(result["text"].count("[REDACTED NETWORK SOURCE]"), 4)
        for useful in ("/mnt/archive nfs rw,vers=4 0 0", "type nfs4 (rw,relatime)",
                       "/mnt/sshfs fuse.sshfs rw", "/dev/mmcblk0p3 /backingfiles xfs",
                       "/dev/loop0 /mnt/cam vfat", "/etc/fstab", "C:/Windows/system32"):
            self.assertIn(useful, result["text"])

    def test_useful_health_and_source_paths_survive_and_controls_are_removed(self):
        text = ("CPU temperature: 49 C\nFree space: 28 GiB\n"
                "nginx.service active; setup.sh returned exit 0\n"
                "FFmpeg version 6.1.1\n"
                "/root/bin/archiveloop started\n"
                "\x1b[31mWARNING: network unavailable\x1b[0m\x00\u202e\n"
                "<script>untrusted log text</script>\n")
        result = self.prepare(text)
        for wanted in ("49 C", "28 GiB", "nginx.service", "setup.sh", "6.1.1", "/root/bin/archiveloop"):
            self.assertIn(wanted, result["text"])
        for control in ("\x1b", "\x00", "\u202e"):
            self.assertNotIn(control, result["text"])
        # The UI must render returned text as text, never HTML.
        self.assertIn("<script>untrusted log text</script>", result["text"])
        self.assertIn(maintenance.SHARED_WARNING, result["text"])

    def test_input_output_and_long_lines_are_bounded(self):
        with self.assertRaises(ValueError):
            maintenance.redact_diagnostics(b"x" * (maintenance.MAX_SHARED_INPUT_BYTES + 1))
        with self.assertRaises(ValueError):
            maintenance.redact_diagnostics("not bytes")
        result = self.prepare("x" * (maintenance.MAX_SHARED_LINE_CHARS + 1))
        self.assertIn("[REDACTED OVERLONG LINE]", result["text"])
        self.assertNotIn("x" * 100, result["text"])
        with patch.object(maintenance, "MAX_SHARED_OUTPUT_BYTES", 400):
            result = self.prepare("CPU: 49 C\n" * 100)
        self.assertLessEqual(len(result["text"].encode("utf-8")), 400)
        self.assertTrue(result["output_truncated"])
        self.assertNotIn("\x00", maintenance.redact_diagnostics(b"\xff\x00")["text"])


class SharingResponseTests(unittest.TestCase):
    def test_fixed_reader_bounded_preview_and_no_extra_command(self):
        class Reader:
            def read(self, log_id, *, limit):
                self.query = (log_id, limit)
                return b"Password=secret\nCPU: 49 C\n", 27
        reader = Reader()
        with patch.object(maintenance.subprocess, "run", side_effect=AssertionError("No subprocess")):
            headers, value = response_data(maintenance.handle("diagnostics-shared", reader))
        self.assertEqual(headers["Status"], "200 OK")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        self.assertEqual(reader.query, ("diagnostics", 512 * 1024))
        self.assertEqual(value["filename"], "teslausb-diagnostics-shared.txt")
        self.assertNotIn("secret", value["text"])
        self.assertEqual(value["warning"], maintenance.SHARED_WARNING)
        self.assertFalse(value["truncated"])
        self.assertEqual(value["source_bytes_limit"], 512 * 1024)

    def test_source_tail_and_output_expansion_limits_are_distinct(self):
        class Reader:
            def read(self, _log_id, *, limit):
                body = b"KEY=x\n" * 50000
                assert len(body) <= limit
                return body, len(body)
        _, value = response_data(maintenance.handle("diagnostics-shared", Reader()))
        self.assertFalse(value["truncated"])
        self.assertTrue(value["output_truncated"])
        self.assertLessEqual(len(value["text"].encode("utf-8")), maintenance.MAX_SHARED_OUTPUT_BYTES)

    def test_missing_and_unsafe_reports_have_fixed_errors(self):
        class Reader:
            def read(self, *_args, **_kwargs):
                raise maintenance.LogUnavailable(reason)
        for reason, status in (("missing", "404 Not Found"), ("unavailable", "503 Service Unavailable")):
            with self.subTest(reason=reason):
                headers, value = response_data(maintenance.handle("diagnostics-shared", Reader()))
                self.assertEqual(headers["Status"], status)
                self.assertFalse(value["ok"])
                self.assertNotIn("/tmp", value["error"])


@unittest.skipUnless(os.name == "posix" and hasattr(os, "O_NOFOLLOW"), "Linux descriptor checks")
class SharedDescriptorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="teslausb-share-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        (self.root / "tmp").mkdir(mode=0o1777)
        (self.root / "tmp").chmod(0o1777)
        self.path = self.root / "tmp/diagnostics.txt"
        self.path.write_bytes(b"PASSWORD=descriptor-only-secret-value\nCPU: 49 C\n")
        self.path.chmod(0o600)
        self.reader = maintenance.LogReader(self.root, root_uid=os.geteuid())

    def test_full_report_not_rewritten_and_smaller_limit_applies(self):
        before = self.path.read_bytes()
        _, result = response_data(maintenance.handle("diagnostics-shared", self.reader))
        self.assertNotIn("descriptor-only-secret-value", result["text"])
        self.assertEqual(self.path.read_bytes(), before)
        prefix = b"SECRET='private continuation\n" + b"x" * maintenance.MAX_SHARED_INPUT_BYTES
        self.path.write_bytes(prefix + b"\n====== network ======\nCPU: 49 C\n")
        _, result = response_data(maintenance.handle("diagnostics-shared", self.reader))
        self.assertTrue(result["truncated"])
        self.assertIn("CPU: 49 C", result["text"])
        self.assertNotIn("private continuation", result["text"])

    def test_symlink_hardlink_wrong_owner_and_writable_report_rejected(self):
        outside = self.root / "private"
        outside.write_bytes(b"private outside report")
        self.path.unlink()
        self.path.symlink_to(outside)
        headers, _ = response_data(maintenance.handle("diagnostics-shared", self.reader))
        self.assertEqual(headers["Status"], "503 Service Unavailable")
        self.path.unlink()
        self.path.write_bytes(b"CPU: 49 C\n")
        self.path.chmod(0o666)
        headers, _ = response_data(maintenance.handle("diagnostics-shared", self.reader))
        self.assertEqual(headers["Status"], "503 Service Unavailable")
        self.path.chmod(0o600)
        self.reader.web_uid = os.geteuid() + 1
        headers, _ = response_data(maintenance.handle("diagnostics-shared", self.reader))
        self.assertEqual(headers["Status"], "503 Service Unavailable")
        self.reader.web_uid = os.geteuid()
        os.link(self.path, self.root / "hardlink")
        headers, _ = response_data(maintenance.handle("diagnostics-shared", self.reader))
        self.assertEqual(headers["Status"], "503 Service Unavailable")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Linux CGI integration")
class SharingBoundaryTests(unittest.TestCase):
    def request(self, method="GET", route="/api/v1/maintenance/logs/diagnostics/shared", **overrides):
        env = {"PATH": "/usr/bin:/bin", "GATEWAY_INTERFACE": "CGI/1.1",
               "HTTP_HOST": "teslausb.local", "REQUEST_METHOD": method,
               "PATH_INFO": route, "QUERY_STRING": ""}
        env.update(overrides)
        result = subprocess.run(["bash", str(CGI_DIR / "api-v1.sh")],
                                capture_output=True, env=env, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return response_data(result.stdout)

    def test_exact_route_dispatched_and_boundaries_still_apply(self):
        headers, value = self.request()
        self.assertIn(headers["Status"], ("200 OK", "404 Not Found", "503 Service Unavailable"))
        self.assertNotEqual(value.get("error"), "Unknown API route.")
        for method in ("POST", "HEAD", "DELETE"):
            headers, _ = self.request(method=method)
            self.assertEqual(headers["Status"], "405 Method Not Allowed")
        for extra, status in (({"QUERY_STRING": "path=/etc/shadow"}, "400 Bad Request"),
                              ({"HTTP_SEC_FETCH_SITE": "cross-site"}, "403 Forbidden"),
                              ({"HTTP_HOST": "evil.example"}, "421 Misdirected Request")):
            headers, _ = self.request(**extra)
            self.assertEqual(headers["Status"], status)
        for route in ("/api/v1/maintenance/logs/setup/shared", "/api/v1/maintenance/logs/diagnostics/shared/extra"):
            headers, _ = self.request(route=route)
            self.assertEqual(headers["Status"], "404 Not Found")


if __name__ == "__main__":
    unittest.main()
