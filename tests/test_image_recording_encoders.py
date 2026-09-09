"""Exercise the image encoder verifier with inert command and rootfs fixtures.

No test mounts an image, invokes sudo/chroot, or executes an image binary.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SOURCE = (REPO / "tools/verify-release-image.sh").read_text(encoding="utf-8")
HELPER = re.search(r"^verify_image_encoders\(\) \{\n.*?^\}", SOURCE, re.M | re.S)[0]
BASH = os.environ.get("TESLAUSB_TEST_BASH") or shutil.which("bash")
MOCKS = r'''
fail() { printf '%s\n' "$*" >&2; exit 1; }
uname() {
  [ "$#" = 1 ] && [ "$1" = -m ] || exit 97
  printf '%s\n' "$MOCK_HOST"
}
dpkg-query() {
  printf '%s\n' "$@" > "$PACKAGE_CALLS"
  printf '%s' "$MOCK_PACKAGE"
  return "$MOCK_PACKAGE_EXIT"
}
file() { printf '%s\n' "$MOCK_FILE_ARCH"; }
sudo() {
  printf '%s\n' "$@" > "$ENCODER_CALLS"
  printf '%s\n' "$MOCK_ENCODERS"
  return "$MOCK_ENCODER_EXIT"
}
'''


class ImageEncoderIntegrationTests(unittest.TestCase):
    def test_fresh_images_install_ffmpeg_once(self):
        packages = (REPO / "pi-gen-sources/00-teslausb-tweaks/00-packages").read_text().splitlines()
        self.assertEqual(packages.count("ffmpeg"), 1)

    def test_capabilities_are_checked_after_readonly_mount(self):
        mounted = SOURCE.index('sudo -n mount -o ro,noload -- "$ROOT_PARTITION" "$ROOT_MOUNT"')
        checked = SOURCE.index('verify_image_encoders "$ROOT_MOUNT"')
        self.assertLess(mounted, checked)
        self.assertIn('mjpeg_encoder_verified: true', SOURCE)
        self.assertNotIn('qemu', HELPER)


@unittest.skipUnless(BASH, "Bash is required for isolated verifier helper tests")
class ImageEncoderVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="teslausb-encoder-verifier-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "root"
        (self.root / "usr/bin").mkdir(parents=True)
        for name in ("ffmpeg", "ffprobe"):
            binary = self.root / "usr/bin" / name
            binary.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
            binary.chmod(0o755)
        self.calls = Path(self.temporary.name) / "encoder-calls"
        self.package_calls = Path(self.temporary.name) / "package-calls"

    def run_check(self, **overrides):
        environment = os.environ.copy()
        environment["PATH"] = str(Path(BASH).parent) + os.pathsep + environment.get("PATH", "")
        environment.update({
            "MOCK_HOST": "aarch64", "MOCK_PACKAGE": "installed\tarm64",
            "MOCK_PACKAGE_EXIT": "0", "MOCK_ENCODER_EXIT": "0",
            "MOCK_FILE_ARCH": "ELF 64-bit LSB pie executable, ARM aarch64",
            "MOCK_ENCODERS": "Encoders:\n V....D mjpeg                MJPEG (Motion JPEG)",
            "PACKAGE_CALLS": self.package_calls.as_posix(),
            "ENCODER_CALLS": self.calls.as_posix(),
        })
        environment.update(overrides)
        return subprocess.run(
            [BASH, "-c", "set -euo pipefail\n" + MOCKS + HELPER + '\nverify_image_encoders "$1"',
             "image-encoder-fixture", self.root.as_posix()],
            env=environment, capture_output=True, text=True, timeout=10)

    def assert_rejected_before_execution(self, message, **overrides):
        result = self.run_check(**overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.calls.exists(), "image execution was attempted after a failed preflight")

    def test_mjpeg_is_verified_with_only_fixed_bounded_unprivileged_arguments(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), [
            "-n", "env", "-i", "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", "LC_ALL=C",
            "timeout", "--signal=TERM", "--kill-after=5s", "20s", "chroot",
            "--userspec=65534:65534", "--groups=65534", self.root.as_posix(),
            "/usr/bin/ffmpeg", "-hide_banner", "-encoders",
        ])
        self.assertEqual(self.package_calls.read_text().splitlines(), [
            "--admindir=" + self.root.as_posix() + "/var/lib/dpkg", "--show",
            r"--showformat=${db:Status-Status}\t${Architecture}", "ffmpeg",
        ])

    def test_foreign_host_never_attempts_image_execution(self):
        self.assert_rejected_before_execution("requires a native aarch64 host", MOCK_HOST="x86_64")
        self.assertFalse(self.package_calls.exists())

    def test_arm32_host_never_attempts_image_execution(self):
        self.assert_rejected_before_execution("requires a native aarch64 host", MOCK_HOST="armv7l")

    def test_missing_package_fails(self):
        self.assert_rejected_before_execution("missing the ffmpeg package", MOCK_PACKAGE_EXIT="1")

    def test_removed_package_fails(self):
        self.assert_rejected_before_execution("installed arm64 ffmpeg package", MOCK_PACKAGE="config-files\tarm64")

    def test_wrong_package_architecture_fails(self):
        self.assert_rejected_before_execution("installed arm64 ffmpeg package", MOCK_PACKAGE="installed\tamd64")

    def test_both_image_executables_are_required(self):
        for name in ("ffmpeg", "ffprobe"):
            with self.subTest(name=name):
                binary = self.root / "usr/bin" / name
                content = binary.read_bytes()
                binary.unlink()
                self.assert_rejected_before_execution("executable is missing")
                binary.write_bytes(content)
                binary.chmod(0o755)

    @unittest.skipUnless(os.name == "posix", "POSIX executable mode enforcement")
    def test_nonexecutable_image_binary_fails(self):
        (self.root / "usr/bin/ffmpeg").chmod(0o644)
        self.assert_rejected_before_execution("not executable: ffmpeg")

    def test_symbolic_image_binary_fails(self):
        binary = self.root / "usr/bin/ffmpeg"
        binary.unlink()
        try:
            binary.symlink_to("ffprobe")
        except OSError as error:
            self.skipTest("Symlinks are unavailable: " + str(error))
        self.assert_rejected_before_execution("symbolic, or not executable: ffmpeg")

    def test_wrong_binary_architecture_fails(self):
        self.assert_rejected_before_execution("executable is not arm64", MOCK_FILE_ARCH="ELF 64-bit LSB, x86-64")

    def test_timed_out_or_failed_encoder_listing_fails(self):
        for code in ("1", "124", "137"):
            with self.subTest(code=code):
                result = self.run_check(MOCK_ENCODER_EXIT=code)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("bounded unprivileged chroot", result.stderr)

    def test_mjpeg_name_must_be_an_actual_video_encoder(self):
        for listing in ("", " V....D other MJPEG (Motion JPEG)", " V....D mjpeg_extra codec",
                        " A....D mjpeg audio", " mjpeg"):
            with self.subTest(listing=listing):
                result = self.run_check(MOCK_ENCODERS=listing)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not provide the MJPEG thumbnail encoder", result.stderr)


if __name__ == "__main__":
    unittest.main()
