"""Read-only logging setup regressions; never change the host's configuration."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "setup/pi/make-root-fs-readonly.sh"

class LoggingConfigurationTests(unittest.TestCase):
    def test_managed_logger_is_bounded_and_ignores_disk_file_rules(self):
        text = (ROOT / "setup/pi/busybox-syslogd-ram.conf").read_text()
        self.assertIn("ExecStart=\nExecStart=/sbin/syslogd -n -C128 -f /dev/null\n", text)
        source = SOURCE.read_text()
        self.assertIn('"${SOURCE_DIR:?}/setup/pi/busybox-syslogd-ram.conf"', source)
        self.assertIn("/etc/systemd/system/busybox-syslogd.service.d/30-teslausb-ram.conf", source)
        self.assertIn("systemctl restart busybox-syslogd.service", source)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Bash and awk")
    def test_mountpoint_field_not_path_prefix_comments_or_source(self):
        match = re.search(r"function fstab_has_mountpoint\(\) \{.*?\n\}", SOURCE.read_text(), re.S)
        self.assertIsNotNone(match)
        cases = [
            ("tmpfs /var/log/nginx tmpfs nodev 0 0\n", False),
            ("# tmpfs /var/log tmpfs defaults 0 0\n", False),
            ("/var/log /elsewhere none bind 0 0\n", False),
            ("tmpfs /var/log-old tmpfs defaults 0 0\n", False),
            ("tmpfs /var/log tmpfs nodev,nosuid 0 0\n", True),
            ("  tmpfs\t/var/log\ttmpfs\tnodev 0 0 # parent\n", True),
        ]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fstab"
            for value, expected in cases:
                with self.subTest(value=value):
                    fixture.write_text(value)
                    result = subprocess.run([shutil.which("bash"), "-c",
                        match[0] + '\nfstab_has_mountpoint "$1" "$2"',
                        "test", "/var/log", str(fixture)], capture_output=True,
                        env={"PATH": os.defpath}, timeout=5)
                    self.assertEqual(0 if expected else 1, result.returncode, result.stderr)

    def test_parent_logs_mount_has_ram_limit(self):
        self.assertIn('if ! ensure_ram_log_mount\n', SOURCE.read_text())
        self.assertIn('tmpfs /var/log tmpfs nodev,nosuid,size=32M,mode=0755 0 0', SOURCE.read_text())
        self.assertNotIn('grep -w -q "/var/log"', SOURCE.read_text())

    def run_parent_mount_helper(self, fixture, preamble=""):
        source = SOURCE.read_text()
        functions = []
        for name in ("fstab_has_mountpoint", "ensure_ram_log_mount"):
            match = re.search(r"function " + name + r"\(\) \{.*?\n\}", source, re.S)
            self.assertIsNotNone(match)
            functions.append(match[0])
        return subprocess.run([shutil.which("bash", path=os.defpath), "-c",
                               preamble + "\n" + "\n".join(functions) +
                               '\nensure_ram_log_mount "$1"\n', "test", str(fixture)],
                              capture_output=True, text=True, env={"PATH": os.defpath}, timeout=5)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Bash and coreutils")
    def test_parent_mount_precedes_first_active_child_and_preserves_other_lines(self):
        parent = "tmpfs /var/log tmpfs nodev,nosuid,size=32M,mode=0755 0 0\n"
        prefix = ("# tmpfs /var/log/commented tmpfs defaults 0 0\n"
                  "  # another /var/log/ignored comment\n"
                  "tmpfs /var/log-old tmpfs defaults 0 0\n"
                  "/var/log/source /unrelated none bind 0 0\n\n")
        children = ("  tmpfs\t/var/log/nginx\ttmpfs\tmode=0755 0 0 # first child\n"
                    "# keep this comment between children\n"
                    "tmpfs /var/log/other/nested tmpfs nodev 0 0\n"
                    "tmpfs /tmp tmpfs defaults 0 0\n")
        cases = ((prefix + children, prefix + parent + children),
                 (prefix, prefix + parent), ("", parent))
        with tempfile.TemporaryDirectory(prefix="teslausb-fstab-order-") as directory:
            fixture = Path(directory) / "fstab"
            for before, expected in cases:
                with self.subTest(before=before):
                    fixture.write_text(before)
                    fixture.chmod(0o640)
                    old_info = fixture.stat()
                    result = self.run_parent_mount_helper(fixture)
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertEqual(expected, fixture.read_text())
                    new_info = fixture.stat()
                    self.assertEqual((old_info.st_uid, old_info.st_gid, old_info.st_mode & 0o7777),
                                     (new_info.st_uid, new_info.st_gid, new_info.st_mode & 0o7777))
                    self.assertFalse(fixture.is_symlink())
                    self.assertEqual(0, self.run_parent_mount_helper(fixture).returncode)
                    self.assertEqual(expected, fixture.read_text())
                    self.assertEqual(new_info.st_ino, fixture.stat().st_ino)
                    self.assertEqual(["fstab"], [entry.name for entry in Path(directory).iterdir()])

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Bash and coreutils")
    def test_existing_exact_parent_is_not_rewritten_or_duplicated(self):
        existing = ("# keep administrator-selected options and whitespace\n"
                    "  tmpfs\t/var/log\ttmpfs\tnodev,nosuid,size=16M 0 0 # existing\n"
                    "tmpfs /var/log/nginx tmpfs defaults 0 0\n")
        with tempfile.TemporaryDirectory(prefix="teslausb-fstab-existing-") as directory:
            fixture = Path(directory) / "fstab"
            fixture.write_text(existing)
            old_info = fixture.stat()
            result = self.run_parent_mount_helper(fixture)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(existing, fixture.read_text())
            self.assertEqual(old_info.st_ino, fixture.stat().st_ino)
            self.assertEqual(old_info.st_mtime_ns, fixture.stat().st_mtime_ns)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Bash and coreutils")
    def test_parent_mount_write_or_metadata_failure_keeps_original_unchanged(self):
        original = "# keep me\ntmpfs /var/log/nginx tmpfs defaults 0 0\n"
        failures = {
            "read": "awk() { return 2; }",
            "temporary": "mktemp() { return 1; }",
            "transform": '''awk_calls=0
awk() {
  awk_calls=$((awk_calls + 1))
  if [ "$awk_calls" -eq 2 ]; then printf 'PARTIAL CANDIDATE'; return 2; fi
  command awk "$@"
}''',
            "owner": "chown() { return 1; }",
            "mode": "chmod() { return 1; }",
            "replace": "mv() { return 1; }",
        }
        with tempfile.TemporaryDirectory(prefix="teslausb-fstab-failure-") as directory:
            fixture = Path(directory) / "fstab"
            fixture.write_text(original)
            old_info = fixture.stat()
            for failure, preamble in failures.items():
                with self.subTest(failure=failure):
                    result = self.run_parent_mount_helper(fixture, preamble)
                    self.assertNotEqual(0, result.returncode, result.stderr)
                    self.assertEqual(original, fixture.read_text())
                    self.assertEqual(old_info.st_ino, fixture.stat().st_ino)
                    self.assertEqual(["fstab"], [entry.name for entry in Path(directory).iterdir()])

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Linux filesystem fixtures")
    def test_parent_mount_rejects_nonregular_symlink_and_hardlink_targets(self):
        with tempfile.TemporaryDirectory(prefix="teslausb-fstab-unsafe-") as directory:
            base = Path(directory)
            target = base / "original"
            original = "tmpfs /var/log/nginx tmpfs defaults 0 0\n"
            target.write_text(original)
            symlink = base / "symlink"
            symlink.symlink_to(target)
            hardlink = base / "hardlink"
            os.link(target, hardlink)
            pipe = base / "pipe"
            os.mkfifo(pipe, 0o600)
            for fixture in (symlink, hardlink, pipe, base / "missing", base):
                with self.subTest(target=fixture.name):
                    result = self.run_parent_mount_helper(fixture)
                    self.assertNotEqual(0, result.returncode, result.stderr)
                    self.assertEqual(original, target.read_text())
            self.assertTrue(symlink.is_symlink())
            self.assertEqual(2, target.stat().st_nlink)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Bash")
    def test_each_logger_setup_failure_stops_setup_without_errexit(self):
        block = re.search(r"function configure_ram_syslog\(\) \{.*?\n\}\n\n"
                          r"if ! configure_ram_syslog\nthen\n.*?\nfi", SOURCE.read_text(), re.S)
        self.assertIsNotNone(block)
        driver = r'''
set +e
stage=0
fake_step() {
  stage=$((stage + 1))
  printf 'STEP %s:' "$stage"
  printf ' <%s>' "$@"
  printf '\n'
  [ "$stage" -ne "$FAIL_STAGE" ]
}
install() { fake_step install "$@"; }
systemctl() { fake_step systemctl "$@"; }
log_progress() { printf '%s\n' "$*"; }
'''
        for failure in range(5):
            with self.subTest(failure=failure):
                result = subprocess.run([shutil.which("bash"), "-c", driver + block[0] +
                                         '\nprintf "SETUP_CONTINUED\\n"\n'],
                                        env={"PATH": os.defpath, "SOURCE_DIR": "/fixture-source",
                                             "FAIL_STAGE": str(failure)},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(0 if failure == 0 else 1, result.returncode, result.stderr)
                steps = [line for line in result.stdout.splitlines() if line.startswith("STEP ")]
                self.assertEqual(4 if failure == 0 else failure, len(steps))
                if failure == 0:
                    self.assertIn("SETUP_CONTINUED", result.stdout)
                    self.assertNotIn("STOP:", result.stdout)
                    self.assertIn("</fixture-source/setup/pi/busybox-syslogd-ram.conf>", result.stdout)
                else:
                    self.assertIn("STOP: could not configure RAM-only system logging", result.stdout)
                    self.assertNotIn("SETUP_CONTINUED", result.stdout)

if __name__ == "__main__":
    unittest.main()
