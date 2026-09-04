import base64
import importlib.util
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("ssh_key_setup", Path(__file__).with_name("ssh_key_setup.py"))
ssh = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ssh)
WIRE = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32) + bytes(range(32))
BLOB = base64.b64encode(WIRE)
KEY = b"ssh-ed25519 " + BLOB + b" codex-teslausb\n"


class KeyTests(unittest.TestCase):
    def test_ed25519_key_and_single_windows_newline(self):
        self.assertEqual(ssh.validate_key(KEY), KEY)
        self.assertEqual(ssh.validate_key(KEY.rstrip() + b"\r\n"), KEY)

    def test_reject_bad_keys_and_options(self):
        for value in (b"", b"restrict " + KEY, KEY + KEY, KEY + b"\n", b"ssh-rsa " + BLOB,
                      KEY.replace(b"ssh-ed25519", b"ssh-ed25518", 1), b"ssh-ed25519 AAAA\n",
                      KEY.replace(b" codex", b"\x00codex"), KEY + b"\xff", KEY.replace(BLOB, BLOB[:-2])):
            with self.subTest(value=value[:20]), self.assertRaises(ssh.EnrollmentError):
                ssh.validate_key(value)

    def test_merge_preserves_existing_bytes_and_newline(self):
        original = b"# old keys\nssh-rsa AAAA old-user"
        self.assertEqual(ssh.merge_key(original, KEY), original + b"\nrestrict,pty " + KEY)
        self.assertEqual(ssh.merge_key(b"", KEY), b"restrict,pty " + KEY)

    def test_same_key_different_comment_is_idempotent(self):
        original = KEY.replace(b"codex-teslausb", b"older comment")
        self.assertEqual(ssh.merge_key(original, KEY), original)

    def test_same_restricted_key_is_idempotent(self):
        original = b"restrict,pty " + KEY.replace(b"codex-teslausb", b"older comment")
        self.assertEqual(ssh.merge_key(original, KEY), original)

    def test_restricted_duplicate_does_not_get_unrestricted_copy(self):
        for options in (b"restrict ", b"pty,restrict ", b'command="echo hello",no-pty ', b'from="192.168.*" '):
            with self.subTest(options=options), self.assertRaises(ssh.EnrollmentError):
                ssh.merge_key(options + KEY, KEY)

    def test_ambiguous_existing_line_is_preserved_by_failing(self):
        with self.assertRaises(ssh.EnrollmentError):
            ssh.merge_key(b'command="unterminated ssh-ed25519 AAAA\n', KEY)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = {"permitrootlogin": "without-password", "pubkeyauthentication": "yes",
                       "authenticationmethods": "any", "authorizedkeysfile": ".ssh/authorized_keys .ssh/authorized_keys2",
                       "pubkeyacceptedalgorithms": "ssh-ed25519,rsa-sha2-512", "usepam": "yes"}

    def test_debian_pam_password_lock_does_not_require_unlocking(self):
        result = ssh.check_policy(self.policy, password_locked=True)
        self.assertTrue(result["password_locked"])
        self.assertEqual(result["root_public_key_policy"], "allowed")
        self.assertIn("pending", result["connection_test"])

    def test_fail_closed_without_weakening_custom_policy(self):
        changes = {"permitrootlogin": "no", "pubkeyauthentication": "no", "authenticationmethods": "publickey,password",
                   "authorizedkeysfile": "none", "pubkeyacceptedalgorithms": "rsa-sha2-512", "usepam": "no",
                   "allowusers": "pi", "denyusers": "root", "allowgroups": "ssh-users", "denygroups": "root",
                   "forcecommand": "internal-sftp", "chrootdirectory": "/locked", "revokedkeys": "/etc/revoked"}
        for name, value in changes.items():
            with self.subTest(name=name), self.assertRaises(ssh.EnrollmentError):
                ssh.check_policy(dict(self.policy, **{name: value}), password_locked=True)

    def test_publickey_as_one_allowed_alternative(self):
        self.policy["authenticationmethods"] = "publickey publickey,password"
        ssh.check_policy(self.policy, password_locked=True)

    def test_parse_duplicate_rejected(self):
        with self.assertRaises(ssh.EnrollmentError):
            ssh.parse_policy("usepam yes\nusepam no\n")

    def test_parse_accepts_multiple_listeners_and_host_keys(self):
        parsed = ssh.parse_policy("listenaddress [::]:22\nlistenaddress 0.0.0.0:22\n"
                                  "hostkey /etc/ssh/ssh_host_rsa_key\nhostkey /etc/ssh/ssh_host_ed25519_key\n"
                                  "usepam yes\npermitrootlogin prohibit-password\n")
        self.assertEqual(parsed, {"usepam": "yes", "permitrootlogin": "prohibit-password"})


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.state = {"directory_existed": True, "original_metadata": {"mode": 0o600, "uid": 0, "gid": 0},
                      "service": {"active": False, "enabled": "disabled"}, "report": {}}
        self.before = b"# existing\n"
        self.after = self.before + KEY
        self.stack = []
        for name in ("_validate_state", "_current_keys", "_atomic_write", "_command", "_service_state", "_sync_directory"):
            patcher = mock.patch.object(ssh, name)
            self.stack.append(patcher)
            setattr(self, name, patcher.start())
        self._validate_state.return_value = (self.before, self.after)
        self._current_keys.return_value = (True, self.before, self.state["original_metadata"])
        self._service_state.side_effect = [self.state["service"], {"active": True, "enabled": "enabled"}]

    def tearDown(self):
        for patcher in reversed(self.stack):
            patcher.stop()

    def test_apply_validates_daemon_before_enable_and_start(self):
        ssh.apply(self.state)
        calls = [item.args[0] for item in self._command.call_args_list]
        self.assertEqual(calls, [["/usr/sbin/sshd", "-t"], ["/usr/bin/systemctl", "enable", "ssh.service"],
                                 ["/usr/bin/systemctl", "start", "ssh.service"]])
        self._atomic_write.assert_called_once()

    def test_daemon_failure_never_enables_ssh(self):
        self._command.side_effect = ssh.EnrollmentError("invalid config")
        with self.assertRaises(ssh.EnrollmentError):
            ssh.apply(self.state)
        self.assertEqual(len(self._command.call_args_list), 1)

    def test_concurrent_key_change_not_overwritten(self):
        self._current_keys.return_value = (True, b"# unrelated change", self.state["original_metadata"])
        with self.assertRaises(ssh.EnrollmentError):
            ssh.apply(self.state)
        self._atomic_write.assert_not_called()

    def test_rollback_exact_original_and_service_state(self):
        self._current_keys.return_value = (True, self.after, self.state["original_metadata"])
        self._service_state.side_effect = [{"active": True, "enabled": "enabled"}]
        ssh.rollback(self.state)
        self.assertEqual(self._atomic_write.call_args.args[1], self.before)
        self.assertEqual([item.args[0][1] for item in self._command.call_args_list], ["stop", "disable"])

    def test_recovery_refuses_overwriting_later_admin_edits(self):
        self._current_keys.return_value = (True, b"# another admin", self.state["original_metadata"])
        with self.assertRaises(ssh.EnrollmentError):
            ssh.recover(self.state)
        self._atomic_write.assert_not_called()
        self._command.assert_not_called()

    def test_active_existing_ssh_is_not_restarted(self):
        self.state["service"] = {"active": True, "enabled": "enabled"}
        self._service_state.side_effect = [self.state["service"], self.state["service"]]
        ssh.apply(self.state)
        self._command.assert_called_once_with(["/usr/sbin/sshd", "-t"])

    def test_runtime_only_service_is_enabled_persistently(self):
        self.state["service"] = {"active": True, "enabled": "enabled-runtime"}
        self._service_state.side_effect = [self.state["service"], {"active": True, "enabled": "enabled"}]
        ssh.apply(self.state)
        self.assertEqual([item.args[0] for item in self._command.call_args_list],
                         [["/usr/sbin/sshd", "-t"], ["/usr/bin/systemctl", "enable", "ssh.service"]])

    def test_runtime_only_service_restored_on_rollback(self):
        self.state["service"] = {"active": True, "enabled": "enabled-runtime"}
        self._service_state.side_effect = [{"active": True, "enabled": "enabled"}]
        ssh.rollback(self.state)
        self.assertEqual([item.args[0] for item in self._command.call_args_list],
                         [["/usr/bin/systemctl", "disable", "ssh.service"],
                          ["/usr/bin/systemctl", "enable", "--runtime", "ssh.service"]])


@unittest.skipUnless(os.name == "posix" and getattr(os, "geteuid", lambda: 1)() == 0,
                     "Root Linux filesystem security test")
class FilesystemTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="teslausb-ssh-tests-", dir="/run")
        self.path = Path(self.directory.name)
        self.root = self.path / "rootfs"
        self.root.mkdir(mode=0o700)
        (self.root / "root").mkdir(mode=0o700)
        self.backup = self.path / "backup"
        self.backup.mkdir(mode=0o700)
        self.patch = mock.patch.object(ssh, "ROOT", self.root)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.directory.cleanup()

    def test_symlink_authorized_keys_rejected(self):
        directory = self.root / "root/.ssh"
        directory.mkdir(mode=0o700)
        target = self.path / "do-not-modify"
        target.write_bytes(b"sentinel")
        (directory / "authorized_keys").symlink_to(target)
        with self.assertRaises((ssh.EnrollmentError, OSError)):
            ssh._current_keys()
        self.assertEqual(target.read_bytes(), b"sentinel")

    def test_symlink_ssh_directory_rejected(self):
        (self.root / "root/.ssh").symlink_to(self.backup)
        with self.assertRaises(ssh.EnrollmentError):
            ssh._current_keys()

    def test_group_writable_root_directory_rejected(self):
        (self.root / "root").chmod(0o770)
        with self.assertRaises(ssh.EnrollmentError):
            ssh._current_keys()

    def test_hardlink_authorized_keys_rejected(self):
        directory = self.root / "root/.ssh"
        directory.mkdir(mode=0o700)
        target = self.path / "other"
        target.write_bytes(KEY)
        os.link(target, directory / "authorized_keys")
        with self.assertRaises(ssh.EnrollmentError):
            ssh._current_keys()

    def _state(self, original=None):
        if original is not None:
            (self.root / "root/.ssh").mkdir(mode=0o700)
            ssh._atomic_write(self.root / "root/.ssh/authorized_keys", original)
            ssh._atomic_write(self.backup / "ssh-authorized-keys.before", original)
        replacement = ssh.merge_key(original or b"", KEY)
        ssh._atomic_write(self.backup / "ssh-authorized-keys.after", replacement)
        return {"version": 1, "backup_dir": str(self.backup), "directory_existed": original is not None,
                "original_sha256": ssh._digest(original) if original is not None else None,
                "replacement_sha256": ssh._digest(replacement),
                "original_metadata": {"mode": 0o600, "uid": 0, "gid": 0} if original is not None else None,
                "service": {"active": True, "enabled": "enabled"}, "report": {}}

    def test_create_and_rollback_absent_keys_and_directory(self):
        state = self._state()
        with mock.patch.object(ssh, "_command"), mock.patch.object(ssh, "_service_state", return_value=state["service"]):
            ssh.apply(state)
            self.assertEqual((self.root / "root/.ssh/authorized_keys").read_bytes(), b"restrict,pty " + KEY)
            ssh.rollback(state)
            ssh.rollback(state)
        self.assertFalse((self.root / "root/.ssh").exists())

    def test_existing_keys_preserved_and_restored_exactly(self):
        original = b"# untouched original without final newline"
        state = self._state(original)
        with mock.patch.object(ssh, "_command"), mock.patch.object(ssh, "_service_state", return_value=state["service"]):
            ssh.apply(state)
            self.assertEqual((self.root / "root/.ssh/authorized_keys").read_bytes(), original + b"\nrestrict,pty " + KEY)
            ssh.rollback(state)
        self.assertEqual((self.root / "root/.ssh/authorized_keys").read_bytes(), original)

    def test_corrupt_backup_rejected_before_key_mutation(self):
        state = self._state()
        (self.backup / "ssh-authorized-keys.after").write_bytes(b"tampered")
        with self.assertRaises(ssh.EnrollmentError):
            ssh.apply(state)
        self.assertFalse((self.root / "root/.ssh").exists())


if __name__ == "__main__":
    unittest.main()
