"""Execute only extracted optional-encoder setup helpers with inert fixtures."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SETUP = (REPO / "setup/pi/configure-web.sh").read_text(encoding="utf-8")
AVAILABLE = re.search(r"^recording_encoder_available\(\) \{\n.*?^\}", SETUP, re.M | re.S).group(0)
CONFIGURE = re.search(r"^configure_optional_recording_encoder\(\) \{\n.*?^\}", SETUP, re.M | re.S).group(0)
BASH = os.environ.get("TESLAUSB_TEST_BASH") or shutil.which("bash")


class OptionalEncoderContractTests(unittest.TestCase):
    def test_image_declares_encoder_and_setup_check_is_bounded(self):
        packages = (REPO / "pi-gen-sources/00-teslausb-tweaks/00-packages").read_text().splitlines()
        self.assertIn("ffmpeg", packages)
        self.assertIn("timeout 10 /usr/bin/ffmpeg -hide_banner -encoders", AVAILABLE)
        self.assertIn("mjpeg", AVAILABLE)
        self.assertNotIn("-i ", AVAILABLE, "Capability checks must never encode footage")

    def test_optional_install_is_guarded_and_essential_setup_continues(self):
        self.assertIn("if DEBIAN_FRONTEND=noninteractive apt-get -y install ffmpeg", CONFIGURE)
        self.assertNotRegex(SETUP, r"(?m)^DEBIAN_FRONTEND=noninteractive apt-get -y install ffmpeg$")
        call = SETUP.index("\nconfigure_optional_recording_encoder\n")
        self.assertLess(call, SETUP.index('install -o root -g root -m 0644 "$SOURCE_DIR/setup/pi/teslausb-trash-cleanup.service"'))
        self.assertLess(call, SETUP.index('"$SOURCE_DIR/teslausb-www/teslausb-web-sudo"'))
        self.assertLess(call, SETUP.index("systemctl restart nginx.service"))


@unittest.skipUnless(BASH, "Bash for isolated setup fixtures")
class OptionalEncoderSetupTests(unittest.TestCase):
    def exercise(self, initial, *, package_succeeds=True, usable_after=True):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            encoder = root / "ffmpeg"
            # The fixture is inert; neither ffmpeg, apt, setup, nor a service is
            # invoked on the test runner. timeout/apt-get are shell mocks.
            if initial:
                encoder.write_text("#!/bin/sh\nexit 0\n")
                encoder.chmod(0o755)
            available = AVAILABLE.replace("/usr/bin/ffmpeg", encoder.as_posix())
            script = "set -eu\n" + "\n".join((
                "usable=" + ("yes" if initial == "usable" else "no"),
                "setup_progress() { printf '%s\\n' \"$1\"; }",
                "timeout() { [ \"$1\" = 10 ]; [ \"$3\" = -hide_banner ]; [ \"$4\" = -encoders ]; "
                "if [ \"$usable\" = yes ]; then printf ' V..... mjpeg   MJPEG encoder fixture\\n'; "
                "else printf ' V..... png   PNG encoder fixture\\n'; fi; }",
                "apt-get() { [ \"$*\" = '-y install ffmpeg' ]; printf 'APT_FIXTURE\\n'; " +
                ("printf '#!/bin/sh\\nexit 0\\n' > '" + encoder.as_posix() + "'; chmod 0755 '" + encoder.as_posix() + "'; "
                 "usable=" + ("yes" if usable_after else "no") + "; return 0; }" if package_succeeds else "return 100; }"),
                available, CONFIGURE,
                "configure_optional_recording_encoder",
                "printf 'ESSENTIAL_SETUP_CONTINUES\\n'"))
            environment = os.environ.copy()
            environment["PATH"] = str(Path(BASH).parent) + os.pathsep + environment.get("PATH", "")
            result = subprocess.run([BASH, "-c", script], capture_output=True, text=True, timeout=5, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ESSENTIAL_SETUP_CONTINUES", result.stdout)
            return result.stdout

    def test_preinstalled_mjpeg_skips_apt(self):
        output = self.exercise("usable")
        self.assertNotIn("APT_FIXTURE", output)
        self.assertNotIn("WARNING", output)

    def test_missing_encoder_can_be_installed_once(self):
        output = self.exercise(None)
        self.assertEqual(output.count("APT_FIXTURE"), 1)
        self.assertNotIn("WARNING", output)

    def test_failed_optional_package_does_not_abort_essential_setup(self):
        output = self.exercise(None, package_succeeds=False)
        self.assertIn("optional ffmpeg installation failed", output)
        self.assertIn("Original-quality playback and downloads remain available", output)

    def test_package_without_mjpeg_warns_and_continues(self):
        output = self.exercise("missing_codec", usable_after=False)
        self.assertIn("encoder is unavailable after package installation", output)
        self.assertEqual(output.count("APT_FIXTURE"), 1)


if __name__ == "__main__":
    unittest.main()
