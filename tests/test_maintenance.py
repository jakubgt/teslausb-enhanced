"""Regression tests for the unprivileged read-only maintenance endpoints."""

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
SPEC = importlib.util.spec_from_file_location("maintenance", CGI_DIR / "maintenance.py")
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)


def split_response(raw):
    head, body = raw.split(b"\r\n\r\n", 1)
    headers = dict(line.split(": ", 1) for line in head.decode("ascii").split("\r\n"))
    return headers, body


class SSHStatusTests(unittest.TestCase):
    def query(self, text, returncode=0):
        result = subprocess.CompletedProcess([], returncode, text)
        with patch.object(maintenance.subprocess, "run", return_value=result) as run:
            status = maintenance.ssh_status()
        args, kwargs = run.call_args
        self.assertEqual(args[0][0], "/usr/bin/systemctl")
        self.assertEqual(args[0][1:3], ["show", "ssh.service"])
        self.assertEqual(kwargs["timeout"], 2)
        self.assertNotIn("shell", kwargs)
        self.assertEqual(kwargs["env"]["LC_ALL"], "C")
        return status

    def test_active_service_is_not_a_verified_listener(self):
        result = self.query("LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n")
        self.assertEqual(result, {"service_state": "active", "enabled_state": "enabled",
                                  "port": 22, "port_source": "default"})
        self.assertNotIn("authenticated", result)

    def test_inactive_and_failed_services(self):
        for state in ("inactive", "failed"):
            with self.subTest(state=state):
                result = self.query("LoadState=loaded\nActiveState=" + state +
                                    "\nUnitFileState=disabled\n")
                self.assertEqual(result["service_state"], state)
                self.assertEqual(result["enabled_state"], "disabled")

    def test_masked_service(self):
        result = self.query("LoadState=masked\nActiveState=inactive\nUnitFileState=masked\n")
        self.assertEqual(result["service_state"], "inactive")
        self.assertEqual(result["enabled_state"], "masked")

    def test_not_installed(self):
        result = self.query("LoadState=not-found\nActiveState=inactive\nUnitFileState=\n")
        self.assertEqual(result["service_state"], "not-installed")
        self.assertIsNone(result["port"])

    def test_transitional_and_malformed_states_are_unknown(self):
        for text in ("LoadState=loaded\nActiveState=activating\n",
                     "LoadState=error\nActiveState=active\n",
                     "LoadState=loaded\nActiveState=<script>alert(1)</script>\n",
                     "LoadState=loaded\nActiveState=active\nActiveState=inactive\n",
                     "x" * 4097):
            with self.subTest(text=text[:70]):
                result = self.query(text)
                self.assertEqual(result["service_state"], "unknown")
                self.assertIsNone(result["port"])

    def test_enabled_state_is_allowlisted(self):
        result = self.query("LoadState=loaded\nActiveState=active\nUnitFileState=<script>\n")
        self.assertEqual(result["enabled_state"], "unknown")

    def test_custom_port_is_never_misrepresented_as_detected(self):
        # Unrequested fields cannot silently turn a default hint into a claim
        # about sshd's effective config, socket activation, or listener owner.
        result = self.query("LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n"
                            "Listen=[::]:2222\nExecStart=/usr/sbin/sshd -p 2222\n")
        self.assertEqual(result["port_source"], "default")
        self.assertEqual(result["port"], 22)

    def test_query_failure_is_not_a_disabled_service(self):
        result = self.query("LoadState=loaded\nActiveState=active\n", returncode=1)
        self.assertEqual(result["service_state"], "unknown")
        self.assertEqual(result["port_source"], "unknown")

    def test_timeout_or_absent_systemctl_is_unknown(self):
        for error in (FileNotFoundError(), subprocess.TimeoutExpired("systemctl", 2)):
            with self.subTest(error=type(error).__name__):
                with patch.object(maintenance.subprocess, "run", side_effect=error):
                    result = maintenance.ssh_status()
                self.assertEqual(result["service_state"], "unknown")
                self.assertIsNone(result["port"])


@unittest.skipUnless(os.name == "posix" and hasattr(os, "O_NOFOLLOW"), "Linux descriptor checks")
class LogReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="teslausb-maintenance-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        for name in ("tmp", "mutable", "boot", "boot/firmware"):
            (self.root / name).mkdir(mode=0o755)
        (self.root / "tmp").chmod(0o1777)
        (self.root / "teslausb").symlink_to("/boot/firmware")
        self.reader = maintenance.LogReader(self.root, root_uid=os.geteuid())

    def save(self, relative, content=b"saved log\n", mode=0o644):
        path = self.root / relative
        path.write_bytes(content)
        path.chmod(mode)
        return path

    def assert_unavailable(self, log_id):
        info = self.reader.metadata(log_id)
        self.assertFalse(info["available"])
        self.assertEqual(info["reason"], "unavailable")
        with self.assertRaises(maintenance.LogUnavailable):
            self.reader.read(log_id)

    def test_all_fixed_locations(self):
        for name, relative in (
            ("diagnostics", "tmp/diagnostics.txt"), ("archiveloop", "mutable/archiveloop.log"),
            ("setup", "boot/firmware/teslausb-headless-setup.log"),
            ("maintenance", "boot/firmware/teslausb-runtime-maintenance.log"),
        ):
            with self.subTest(name=name):
                self.save(relative)
                self.assertEqual(self.reader.read(name), (b"saved log\n", 10))
                self.assertEqual(self.reader.metadata(name), {
                    "available": True, "reason": "available", "size_bytes": 10,
                    "truncated": False,
                })

    def test_private_web_owned_diagnostics_is_readable(self):
        self.save("tmp/diagnostics.txt", mode=0o600)
        self.assertTrue(self.reader.metadata("diagnostics")["available"])

    def test_boot_fat_default_0755_file_mode_is_readable(self):
        self.save("boot/firmware/teslausb-headless-setup.log", mode=0o755)
        self.assertTrue(self.reader.metadata("setup")["available"])

    def test_missing_log_is_distinct(self):
        info = self.reader.metadata("diagnostics")
        self.assertEqual(info["reason"], "missing")
        headers, _ = split_response(maintenance.handle("diagnostics", self.reader))
        self.assertEqual(headers["Status"], "404 Not Found")

    def test_never_accepts_paths_or_parameters_as_log_ids(self):
        for name in ("/etc/shadow", "../setup", "setup?path=/etc/shadow", "setup\r\nX: y", ""):
            with self.subTest(name=name):
                headers, _ = split_response(maintenance.handle(name, self.reader))
                self.assertEqual(headers["Status"], "404 Not Found")

    def test_final_symlink_and_dangling_symlink_rejected(self):
        outside = self.save("secret", b"must not escape")
        target = self.root / "tmp/diagnostics.txt"
        for destination in (outside, self.root / "nonexistent"):
            with self.subTest(destination=destination):
                target.symlink_to(destination)
                self.assert_unavailable("diagnostics")
                target.unlink()

    def test_parent_symlink_rejected(self):
        original = self.root / "mutable"
        original.rmdir()
        original.symlink_to(self.root / "boot/firmware")
        self.save("boot/firmware/archiveloop.log")
        self.assert_unavailable("archiveloop")

    def test_boot_alias_only_accepts_the_two_fixed_destinations(self):
        alias = self.root / "teslausb"
        self.save("boot/teslausb-headless-setup.log")
        self.save("boot/firmware/teslausb-headless-setup.log")
        for target in ("/boot", "boot", "/boot/firmware", "boot/firmware"):
            alias.unlink()
            alias.symlink_to(target)
            self.assertTrue(self.reader.metadata("setup")["available"])
        for target in ("/tmp", "/boot/../tmp", "/boot/firmware/other", "../boot"):
            alias.unlink()
            alias.symlink_to(target)
            self.assert_unavailable("setup")

    def test_boot_alias_cannot_be_a_directory(self):
        (self.root / "teslausb").unlink()
        (self.root / "teslausb").mkdir()
        self.assert_unavailable("setup")

    def test_boot_destination_symlink_rejected(self):
        (self.root / "boot/firmware").rmdir()
        (self.root / "boot/firmware").symlink_to(self.root / "tmp")
        self.save("tmp/teslausb-headless-setup.log")
        self.assert_unavailable("setup")

    def test_group_or_world_writable_files_rejected(self):
        for mode in (0o664, 0o646, 0o666):
            with self.subTest(mode=mode):
                self.save("mutable/archiveloop.log", mode=mode)
                self.assert_unavailable("archiveloop")

    def test_wrong_file_owner_rejected_without_needing_root(self):
        self.save("tmp/diagnostics.txt")
        self.reader.web_uid = os.geteuid() + 1
        self.assert_unavailable("diagnostics")

    def test_unsafe_parent_permissions_rejected(self):
        self.save("mutable/archiveloop.log")
        (self.root / "mutable").chmod(0o777)
        self.assert_unavailable("archiveloop")

    def test_tmp_must_be_sticky_if_writable(self):
        self.save("tmp/diagnostics.txt")
        (self.root / "tmp").chmod(0o777)
        self.assert_unavailable("diagnostics")

    def test_hardlinked_files_rejected(self):
        path = self.save("tmp/diagnostics.txt")
        os.link(path, self.root / "another-name")
        self.assert_unavailable("diagnostics")

    def test_fifo_and_directory_rejected_without_blocking(self):
        path = self.root / "tmp/diagnostics.txt"
        os.mkfifo(path, 0o600)
        self.assert_unavailable("diagnostics")
        path.unlink()
        path.mkdir()
        self.assert_unavailable("diagnostics")

    def test_tail_is_bounded_and_headers_report_truncation(self):
        size = maintenance.MAX_LOG_BYTES
        self.save("mutable/archiveloop.log", b"old prefix\n" + b"x" * size)
        headers, body = split_response(maintenance.handle("archiveloop", self.reader))
        self.assertEqual(body, b"x" * size)
        self.assertEqual(headers["X-TeslaUSB-Truncated"], "true")
        self.assertEqual(headers["X-TeslaUSB-Original-Size"], str(size + 11))
        self.assertEqual(headers["Content-Length"], str(size))
        self.assertEqual(headers["Content-Type"], "text/plain; charset=utf-8")
        self.assertEqual(headers["Content-Disposition"], 'attachment; filename="archiveloop.log"')
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_atomic_log_replacement_does_not_switch_the_open_file(self):
        path = self.save("tmp/diagnostics.txt", b"original")
        original_open = self.reader.open

        def swap_after_open(name):
            fd, size = original_open(name)
            path.rename(self.root / "tmp/old-diagnostics.txt")
            self.save("tmp/diagnostics.txt", b"replacement")
            return fd, size

        with patch.object(self.reader, "open", side_effect=swap_after_open):
            self.assertEqual(self.reader.read("diagnostics"), (b"original", 8))

    def test_final_symlink_swapped_before_open_is_rejected(self):
        path = self.save("tmp/diagnostics.txt")
        outside = self.save("secret", b"must not escape")
        original_open = os.open

        def swap_before_open(name, flags, *args, **kwargs):
            if name == "diagnostics.txt":
                path.unlink()
                path.symlink_to(outside)
            return original_open(name, flags, *args, **kwargs)

        with patch.object(maintenance.os, "open", side_effect=swap_before_open):
            with self.assertRaises(maintenance.LogUnavailable):
                self.reader.read("diagnostics")

    def test_growth_does_not_exceed_initial_snapshot_size(self):
        path = self.save("tmp/diagnostics.txt", b"original")
        original_open = self.reader.open

        def grow_after_open(name):
            fd, size = original_open(name)
            with path.open("ab") as output:
                output.write(b"new data")
            return fd, size

        with patch.object(self.reader, "open", side_effect=grow_after_open):
            self.assertEqual(self.reader.read("diagnostics"), (b"original", 8))

    def test_permission_error_is_explicit_unavailable(self):
        with patch.object(self.reader, "open", side_effect=maintenance.LogUnavailable()):
            headers, body = split_response(maintenance.handle("setup", self.reader))
        self.assertEqual(headers["Status"], "503 Service Unavailable")
        self.assertNotIn(b"/teslausb", body)

    def test_status_has_schema_and_all_log_entries(self):
        with patch.object(maintenance, "ssh_status", return_value={"service_state": "unknown"}):
            headers, body = split_response(maintenance.handle("status", self.reader))
        self.assertEqual(headers["Status"], "200 OK")
        data = json.loads(body)
        self.assertEqual(data["schema_version"], 1)
        self.assertEqual(set(data["logs"]), set(maintenance.LOGS))


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Linux CGI integration")
class CGIBoundaryTests(unittest.TestCase):
    def run_cgi(self, route="/api/v1/maintenance", method="GET", dispatcher=False, **overrides):
        env = {"PATH": "/usr/bin:/bin", "GATEWAY_INTERFACE": "CGI/1.1",
               "HTTP_HOST": "teslausb.local", "REQUEST_METHOD": method,
               "PATH_INFO": route, "QUERY_STRING": ""}
        env.update(overrides)
        script = "api-v1.sh" if dispatcher else "maintenance.sh"
        result = subprocess.run(["bash", str(CGI_DIR / script)],
                                capture_output=True, env=env, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return split_response(result.stdout)

    def test_get_status_is_read_only_and_available(self):
        headers, body = self.run_cgi()
        self.assertEqual(headers["Status"], "200 OK")
        self.assertEqual(json.loads(body)["schema_version"], 1)

    def test_api_dispatcher_routes_maintenance(self):
        headers, body = self.run_cgi(dispatcher=True)
        self.assertEqual(headers["Status"], "200 OK")
        self.assertEqual(json.loads(body)["schema_version"], 1)
        headers, _ = self.run_cgi(route="/api/v1/maintenance/logs/shadow", dispatcher=True)
        self.assertEqual(headers["Status"], "404 Not Found")
        headers, _ = self.run_cgi(method="POST", dispatcher=True)
        self.assertEqual(headers["Status"], "405 Method Not Allowed")

    def test_other_methods_rejected(self):
        for method in ("POST", "PUT", "DELETE", "HEAD"):
            with self.subTest(method=method):
                headers, _ = self.run_cgi(method=method)
                self.assertEqual(headers["Status"], "405 Method Not Allowed")

    def test_query_parameters_never_select_paths_or_commands(self):
        for query in ("/etc/shadow", "path=/etc/shadow", "cmd=id", "%00", "x%0D%0AX:evil"):
            with self.subTest(query=query):
                headers, _ = self.run_cgi(QUERY_STRING=query)
                self.assertEqual(headers["Status"], "400 Bad Request")

    def test_unknown_and_traversal_routes_rejected(self):
        for route in ("/api/v1/maintenance/logs/../setup", "/api/v1/maintenance/logs/%2e%2e",
                      "/api/v1/maintenance/logs/shadow", "/api/v1/maintenance/logs/setup/extra"):
            with self.subTest(route=route):
                headers, _ = self.run_cgi(route=route)
                self.assertEqual(headers["Status"], "404 Not Found")

    def test_host_and_cross_site_guards_preserved(self):
        for env, status in (({"HTTP_HOST": "evil.example"}, "421 Misdirected Request"),
                            ({"HTTP_HOST": ""}, "400 Bad Request"),
                            ({"HTTP_SEC_FETCH_SITE": "cross-site"}, "403 Forbidden"),
                            ({"HTTP_ORIGIN": "http://evil.example"}, "403 Forbidden")):
            with self.subTest(env=env):
                headers, _ = self.run_cgi(**env)
                self.assertEqual(headers["Status"], status)

    def test_request_environment_cannot_supply_a_helper(self):
        headers, body = self.run_cgi(TESLAUSB_MAINTENANCE_HELPER="/bin/false",
                                     PYTHONPATH="/no-such-module-path",
                                     PYTHONSTARTUP="/bin/false", SYSTEMD_PAGER="/bin/false")
        self.assertEqual(headers["Status"], "200 OK")
        self.assertIn("logs", json.loads(body))


if __name__ == "__main__":
    unittest.main()
