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
        self.assertIn('if ! fstab_has_mountpoint /var/log\n', SOURCE.read_text())
        self.assertIn('tmpfs /var/log tmpfs nodev,nosuid,size=32M,mode=0755 0 0', SOURCE.read_text())
        self.assertNotIn('grep -w -q "/var/log"', SOURCE.read_text())

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
