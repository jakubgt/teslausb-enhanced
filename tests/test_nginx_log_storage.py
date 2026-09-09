"""Test only the extracted log-directory helper; never configure a host nginx."""

import errno
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SETUP = (REPO / "setup/pi/configure-web.sh").read_text(encoding="utf-8")
HELPER = re.search(r"^configure_nginx_log_storage\(\) \{\n.*?^\}", SETUP, re.M | re.S).group(0)
BASH = os.environ.get("TESLAUSB_TEST_BASH") or shutil.which("bash")


def fixture_helper(base):
    return HELPER.replace("/var/log/nginx", (base / "var/log/nginx").as_posix()).replace(
        "[ -L /var/log ]", "[ -L '" + (base / "var/log").as_posix() + "' ]").replace(
        "[ -L /var ]", "[ -L '" + (base / "var").as_posix() + "' ]").replace(
        "for parent in /var /var/log", "for parent in '" + (base / "var").as_posix() +
        "' '" + (base / "var/log").as_posix() + "'")


class LogMountContractTests(unittest.TestCase):
    def test_fstab_and_fresh_mount_use_the_same_explicit_policy(self):
        options = "nodev,nosuid,mode=0755,uid=0,gid=0"
        self.assertIn('echo "tmpfs /var/log/nginx tmpfs ' + options + ' 0 0" >> /etc/fstab', SETUP)
        self.assertIn('mount -t tmpfs -o ' + options + ' tmpfs "$log_dir"', HELPER)
        self.assertNotIn('echo "tmpfs /var/log/nginx tmpfs nodev,nosuid 0 0"', SETUP)
        self.assertIn('echo "tmpfs /var/lib/nginx tmpfs nodev,nosuid 0 0"', SETUP)

    def test_directory_only_correction_precedes_package_service_activity(self):
        call = SETUP.index("\nconfigure_nginx_log_storage\n")
        self.assertLess(call, SETUP.index("apt-get -y install nginx"))
        self.assertLess(call, SETUP.index("systemctl stop nginx.service"))
        self.assertIn('findmnt --mountpoint "$log_dir" --noheadings --output FSTYPE', HELPER)
        self.assertIn('chown --no-dereference 0:0 -- "$log_dir"', HELPER)
        self.assertIn('chmod 0755 -- "$log_dir"', HELPER)
        self.assertNotRegex(HELPER, r"(?m)^\s*(?:sysctl|rm|umount|systemctl)\b")
        self.assertNotIn("-R", HELPER)


@unittest.skipUnless(BASH, "Bash is required for isolated helper fixtures")
class LogMountHelperTests(unittest.TestCase):
    def exercise(self, base, *, mounted=True, filesystem="tmpfs", mount_ok=True, result_mode="0:0:755",
                 parent_stat="0 755", options="rw,nodev,nosuid,relatime", fail_operation=""):
        if not (base / "var").exists() and not (base / "var").is_symlink():
            (base / "var/log").mkdir(parents=True)
        commands = base / "commands"
        script = "set -eu\n" + "\n".join((
            "record() { printf '%s\\n' \"$*\" >> '" + commands.as_posix() + "'; }",
            "mountpoint() { return " + ("0" if mounted else "1") + "; }",
            "mkdir() { [ '" + fail_operation + "' != mkdir ]; }",
            "mount() { record mount \"$@\"; return " + ("0" if mount_ok else "1") + "; }",
            "findmnt() { if [ \"$5\" = FSTYPE ]; then printf '%s\\n' '" + filesystem +
            "'; else printf '%s\\n' '" + options + "'; fi; }",
            "chown() { record chown \"$@\"; [ '" + fail_operation + "' != chown ]; }",
            "chmod() { record chmod \"$@\"; [ '" + fail_operation + "' != chmod ]; }",
            "stat() { if [ \"$2\" = '%u %a' ]; then printf '%s\\n' '" + parent_stat +
            "'; else printf '%s\\n' '" + result_mode + "'; fi; }",
            fixture_helper(base), "if configure_nginx_log_storage; then exit 0; else exit 1; fi"))
        environment = os.environ.copy()
        environment["PATH"] = str(Path(BASH).parent) + os.pathsep + environment.get("PATH", "")
        result = subprocess.run([BASH, "-c", script], env=environment,
                                capture_output=True, text=True, timeout=5)
        operations = commands.read_text().splitlines() if commands.exists() else []
        return result, operations

    def test_fresh_mount_has_explicit_options_and_corrects_only_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            result, operations = self.exercise(base, mounted=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = (base / "var/log/nginx").as_posix()
            self.assertEqual(operations, [
                "mount -t tmpfs -o nodev,nosuid,mode=0755,uid=0,gid=0 tmpfs " + expected,
                "chown --no-dereference 0:0 -- " + expected, "chmod 0755 -- " + expected])

    def test_existing_mount_is_not_stacked_or_unmounted(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            logs = base / "var/log/nginx"
            logs.mkdir(parents=True)
            retained = logs / "access.log"
            retained.write_bytes(b"keep this existing log\n")
            result, operations = self.exercise(base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(operations), 2)
            self.assertTrue(all(line.startswith(("chown ", "chmod ")) for line in operations))
            self.assertEqual(retained.read_bytes(), b"keep this existing log\n")

    def test_non_tmpfs_and_failed_mount_do_not_change_permissions(self):
        for settings in ({"filesystem": "ext4"}, {"mounted": False, "mount_ok": False}):
            with self.subTest(settings=settings), tempfile.TemporaryDirectory() as temporary:
                result, operations = self.exercise(Path(temporary), **settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(line.startswith(("chown ", "chmod ")) for line in operations))

    def test_failed_directory_verification_stops_setup(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, _ = self.exercise(Path(temporary), result_mode="0:0:1777")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("was not corrected", result.stderr)

    def test_unsafe_parents_or_missing_mount_protections_are_rejected(self):
        for settings in ({"parent_stat": "33 755"}, {"parent_stat": "0 777"},
                         {"options": "ro,nodev,nosuid"}, {"options": "rw,nosuid"},
                         {"options": "rw,nodev"}, {"filesystem": "tmpfs\ntmpfs"}):
            with self.subTest(settings=settings), tempfile.TemporaryDirectory() as temporary:
                result, operations = self.exercise(Path(temporary), **settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(line.startswith(("chown ", "chmod ")) for line in operations))

    def test_mutation_failures_propagate_even_from_a_conditional_caller(self):
        for operation in ("mkdir", "chown", "chmod"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as temporary:
                result, _ = self.exercise(Path(temporary), fail_operation=operation)
                self.assertNotEqual(result.returncode, 0)

    def test_non_directory_target_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / "var/log").mkdir(parents=True)
            (base / "var/log/nginx").write_bytes(b"preserve me")
            result, operations = self.exercise(base)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(operations, [])
            self.assertEqual((base / "var/log/nginx").read_bytes(), b"preserve me")

    @unittest.skipUnless(os.name == "posix", "POSIX symlink fixtures")
    def test_symlinked_target_or_parent_is_rejected(self):
        for component in ("var", "var/log", "var/log/nginx"):
            with self.subTest(component=component), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                target = base / component
                target.parent.mkdir(parents=True, exist_ok=True)
                outside = base / "outside"
                outside.mkdir()
                target.symlink_to(outside, target_is_directory=True)
                result, operations = self.exercise(base)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(operations, [])
                self.assertEqual(list(outside.iterdir()), [])


def kernel_fixture(base):
    """Runs only in a private mount namespace under sudo, against this fixture."""
    assert os.geteuid() == 0 and base.name.startswith("teslausb-nginx-log-test-")
    assert base.is_dir() and not base.is_symlink()
    protected_regular = Path("/proc/sys/fs/protected_regular").read_text()
    assert int(protected_regular) >= 1
    owner = base.stat()
    logs = base / "var/log/nginx"
    logs.mkdir(parents=True)
    mounted = False
    try:
        subprocess.run(["mount", "-t", "tmpfs", "-o", "nodev,nosuid,size=4m", "tmpfs", str(logs)], check=True)
        mounted = True
        assert stat.S_IMODE(logs.stat().st_mode) == 0o1777
        logfile = logs / "error.log"
        logfile.write_bytes(b"preserved worker log\n")
        os.chown(logfile, 65534, 0)
        os.chmod(logfile, 0o644)
        before = (logfile.stat(), logfile.read_bytes())
        try:
            descriptor = os.open(logfile, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        except OSError as error:
            assert error.errno == errno.EACCES
        else:
            os.close(descriptor)
            raise AssertionError("Kernel did not reproduce protected_regular rejection")

        config = base / "nginx.conf"
        config.write_text('error_log "' + logfile.as_posix() + '";\n'
                          'pid "' + (base / "nginx.pid").as_posix() + '";\n'
                          'events {}\nhttp { access_log off; }\n')
        # -e prevents nginx's initial logger from opening its compiled-in host
        # log before it reads our entirely private configuration.
        command = [shutil.which("nginx"), "-e", "stderr", "-p", str(base) + "/", "-c", str(config), "-t"]
        failed = subprocess.run(command, capture_output=True, text=True, timeout=10)
        assert failed.returncode != 0 and "Permission denied" in failed.stderr
        helper = "set -eu\n" + fixture_helper(base) + "\nconfigure_nginx_log_storage\n"
        subprocess.run(["bash", "-c", helper], check=True, timeout=10)
        directory = logs.stat()
        assert (directory.st_uid, directory.st_gid, stat.S_IMODE(directory.st_mode)) == (0, 0, 0o755)
        after = logfile.stat()
        assert (after.st_ino, after.st_uid, after.st_gid, stat.S_IMODE(after.st_mode)) == (
            before[0].st_ino, 65534, 0, 0o644)
        assert logfile.read_bytes() == before[1]
        descriptor = os.open(logfile, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        os.close(descriptor)
        checked = subprocess.run(command, capture_output=True, text=True, timeout=10)
        assert checked.returncode == 0, checked.stderr
        # Repeating setup must preserve the existing mount and its log inode.
        subprocess.run(["bash", "-c", helper], check=True, timeout=10)
        assert logfile.stat().st_ino == before[0].st_ino
        assert Path("/proc/sys/fs/protected_regular").read_text() == protected_regular
    finally:
        if mounted:
            subprocess.run(["umount", "--", str(logs)], check=True)
        # Return fixture directories to the creating test runner for cleanup.
        for directory in (logs, logs.parent, logs.parent.parent):
            os.chown(directory, owner.st_uid, owner.st_gid)
    print("protected_regular reproduction and isolated nginx -t recovery passed")


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux protected_regular and mount namespaces")
class LinuxLogPermissionTests(unittest.TestCase):
    def test_real_tmpfs_protected_regular_and_nginx_config_reopen(self):
        for command in ("sudo", "unshare", "mount", "umount", "mountpoint", "findmnt", "nginx", "bash"):
            if not shutil.which(command):
                self.skipTest("Missing isolated-kernel fixture dependency: " + command)
        protected = Path("/proc/sys/fs/protected_regular")
        if not protected.is_file() or int(protected.read_text()) < 1:
            self.skipTest("Host does not enable protected_regular; test never changes host sysctls")
        probe = subprocess.run(["sudo", "-n", "unshare", "--mount", "--propagation", "private", "true"],
                               capture_output=True, text=True, timeout=5)
        if probe.returncode:
            self.skipTest("Passwordless sudo/private mount namespace unavailable")
        with tempfile.TemporaryDirectory(prefix="teslausb-nginx-log-test-") as temporary:
            result = subprocess.run(["sudo", "-n", "unshare", "--mount", "--propagation", "private",
                                     sys.executable, str(Path(__file__).resolve()), "--kernel-fixture", temporary],
                                    capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("nginx -t recovery passed", result.stdout)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--kernel-fixture":
        kernel_fixture(Path(sys.argv[2]))
    else:
        unittest.main()
