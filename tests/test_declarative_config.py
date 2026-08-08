import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = (
    REPO_ROOT
    / "pi-gen-sources"
    / "00-teslausb-tweaks"
    / "files"
    / "teslausb_config.py"
)
LOADER_PATH = HELPER_PATH.with_name("teslausb-config-loader.sh")
NODE_TOOL_PATH = REPO_ROOT / "tools" / "teslausb-config.js"
SPEC = importlib.util.spec_from_file_location("teslausb_config", HELPER_PATH)
assert SPEC and SPEC.loader
CONFIG = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CONFIG
SPEC.loader.exec_module(CONFIG)


def valid_document():
    return {
        "schema_version": 1,
        "variables": {
            "SSID": "Garage $(touch /tmp/not-executed)",
            "WIFIPASS": "literal $HOME and `whoami`",
            "ARCHIVE_SYSTEM": "none",
            "CAM_SIZE": "40G",
            "WEB_USERNAME": "viewer",
            "WEB_PASSWORD": "correct horse battery staple",
            "RCLONE_FLAGS": ["--transfers", "2"],
            "ARCHIVE_RECENTCLIPS": False,
        },
    }


class DeclarativeConfigTests(unittest.TestCase):
    def write_document(self, document):
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "teslausb_setup.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.addCleanup(directory.cleanup)
        return path

    def test_valid_document_and_emit_are_data_only(self):
        variables, warnings = CONFIG.load_config(self.write_document(valid_document()))
        self.assertEqual(warnings, [])
        self.assertEqual(variables["SSID"], "Garage $(touch /tmp/not-executed)")
        original_stdout = sys.stdout
        binary = io.BytesIO()
        wrapper = io.TextIOWrapper(binary, encoding="utf-8")
        sys.stdout = wrapper
        try:
            CONFIG.emit0(variables)
            wrapper.flush()
        finally:
            sys.stdout = original_stdout
            wrapper.detach()
        records = binary.getvalue().split(b"\0")
        self.assertIn(b"Garage $(touch /tmp/not-executed)", records)
        self.assertIn(b"A", records)
        self.assertIn(b"RCLONE_FLAGS", records)

    def test_unknown_variable_is_rejected(self):
        document = valid_document()
        document["variables"]["BASH_ENV"] = "/tmp/execute-me"
        with self.assertRaisesRegex(CONFIG.ConfigError, "unsupported variable"):
            CONFIG.load_config(self.write_document(document))

    def test_boolean_strings_are_rejected(self):
        document = valid_document()
        document["variables"]["ARCHIVE_RECENTCLIPS"] = "false"
        with self.assertRaisesRegex(CONFIG.ConfigError, "JSON boolean"):
            CONFIG.load_config(self.write_document(document))

    def test_duplicate_json_keys_are_rejected(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "teslausb_setup.json"
        path.write_text(
            '{"schema_version":1,"schema_version":1,"variables":{}}',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(CONFIG.ConfigError, "duplicate JSON key"):
            CONFIG.load_config(path)

    def test_archive_specific_requirements_are_enforced(self):
        document = valid_document()
        document["variables"]["ARCHIVE_SYSTEM"] = "cifs"
        with self.assertRaisesRegex(CONFIG.ConfigError, "ARCHIVE_SERVER is required"):
            CONFIG.load_config(self.write_document(document))

    def test_unsafe_web_password_is_rejected(self):
        document = valid_document()
        document["variables"]["WEB_PASSWORD"] = "password"
        with self.assertRaises(CONFIG.ConfigError):
            CONFIG.load_config(self.write_document(document))

    def test_web_hosts_and_release_pin_are_strict(self):
        document = valid_document()
        document["variables"]["WEB_ALLOWED_HOSTS"] = "teslausb.local, 192.168.7.2 [fd00::12]"
        document["variables"]["WEBUI_RELEASE"] = "v1.2.3"
        document["variables"]["WEBUI_SHA256"] = "a" * 64
        CONFIG.load_config(self.write_document(document))
        document["variables"]["WEB_ALLOWED_HOSTS"] = "example.test:8443"
        with self.assertRaisesRegex(CONFIG.ConfigError, "without ports"):
            CONFIG.load_config(self.write_document(document))
        document["variables"]["WEB_ALLOWED_HOSTS"] = "teslausb.local"
        document["variables"]["WEBUI_RELEASE"] = "latest"
        with self.assertRaisesRegex(CONFIG.ConfigError, "immutable tag"):
            CONFIG.load_config(self.write_document(document))

    def test_keep_awake_and_web_auth_relationships_are_enforced(self):
        document = valid_document()
        document["variables"]["WEB_AUTH_DISABLED"] = True
        with self.assertRaisesRegex(CONFIG.ConfigError, "cannot be combined"):
            CONFIG.load_config(self.write_document(document))
        document = valid_document()
        document["variables"]["TESLA_BLE_VIN"] = "not-a-vin"
        document["variables"]["SENTRY_CASE"] = 1
        with self.assertRaisesRegex(CONFIG.ConfigError, "17-character VIN"):
            CONFIG.load_config(self.write_document(document))
        document["variables"]["TESLA_BLE_VIN"] = "5YJ3E1EA7KF000001"
        CONFIG.load_config(self.write_document(document))

    def test_line_config_and_path_injection_values_are_rejected(self):
        bad_values = {
            "AP_IP": "192.168.66.1/e touch /tmp/owned",
            "AP_SSID": "safe\ninterface=wlan0",
            "ARCHIVE_SERVER": "nas.local\n/tmp/owned /tmp ext4 defaults 0 0",
            "TIME_ZONE": "../../../etc/passwd",
            "TRIGGER_FILE_SAVED": "../../outside",
        }
        for name, value in bad_values.items():
            with self.subTest(name=name):
                document = valid_document()
                document["variables"][name] = value
                with self.assertRaises(CONFIG.ConfigError):
                    CONFIG.load_config(self.write_document(document))

    def test_data_drive_device_paths_reject_traversal_spellings(self):
        valid_paths = (
            "/dev/sda",
            "/dev/mmcblk0",
            "/dev/nvme0n1",
            "/dev/disk/by-id/usb-SanDisk_Ultra_Fit-0:0",
        )
        invalid_paths = (
            "/dev/../sda",
            "/dev/sda/../sdb",
            "/dev/disk/./by-id/device",
            "/dev//sda",
            "/dev/sda/",
            "/dev/.hidden",
            "/tmp/sda",
        )
        for data_drive in valid_paths:
            with self.subTest(data_drive=data_drive, expected="valid"):
                document = valid_document()
                document["variables"]["DATA_DRIVE"] = data_drive
                CONFIG.load_config(self.write_document(document))
        for data_drive in invalid_paths:
            with self.subTest(data_drive=data_drive, expected="invalid"):
                document = valid_document()
                document["variables"]["DATA_DRIVE"] = data_drive
                with self.assertRaisesRegex(CONFIG.ConfigError, "without traversal"):
                    CONFIG.load_config(self.write_document(document))

    def test_ap_and_archive_structural_values_are_validated(self):
        document = valid_document()
        document["variables"].update({
            "AP_SSID": "TeslaUSB road AP",
            "AP_PASS": "a private AP passphrase",
            "AP_IP": "192.168.66.1",
            "TIME_ZONE": "America/Chicago",
            "TRIGGER_FILE_SAVED": "ARCHIVE_UPLOADED",
        })
        CONFIG.load_config(self.write_document(document))

        document["variables"]["AP_PASS"] = "x" * 64
        with self.assertRaisesRegex(CONFIG.ConfigError, "8-63"):
            CONFIG.load_config(self.write_document(document))

        document = valid_document()
        document["variables"].update({
            "ARCHIVE_SYSTEM": "nfs",
            "ARCHIVE_SERVER": "nas.local",
            "SHARE_NAME": "relative/export",
        })
        with self.assertRaisesRegex(CONFIG.ConfigError, "absolute exported path"):
            CONFIG.load_config(self.write_document(document))

    def test_integer_ranges_and_notification_dependencies_are_enforced(self):
        document = valid_document()
        document["variables"]["ARCHIVE_DELAY"] = -1
        with self.assertRaisesRegex(CONFIG.ConfigError, "between 0 and 86400"):
            CONFIG.load_config(self.write_document(document))

        document = valid_document()
        document["variables"]["PUSHOVER_ENABLED"] = True
        with self.assertRaisesRegex(CONFIG.ConfigError, "PUSHOVER_USER_KEY is required"):
            CONFIG.load_config(self.write_document(document))
        document["variables"]["PUSHOVER_USER_KEY"] = "put_your_userkey_here"
        document["variables"]["PUSHOVER_APP_KEY"] = "put_your_appkey_here"
        with self.assertRaisesRegex(CONFIG.ConfigError, "sample placeholder"):
            CONFIG.load_config(self.write_document(document))

        document = valid_document()
        document["variables"]["NOTIFICATION_COMMAND_ENABLED"] = True
        with self.assertRaisesRegex(CONFIG.ConfigError, "NOTIFICATION_COMMAND_START or"):
            CONFIG.load_config(self.write_document(document))

    def test_loader_allowlist_matches_runtime_schema(self):
        loader = LOADER_PATH.read_text(encoding="utf-8")
        def shell_names(category):
            match = re.search(
                rf"readonly -a TESLAUSB_DECLARATIVE_{category}_NAMES=\(\n(?P<names>.*?)\n\)",
                loader,
                re.DOTALL,
            )
            self.assertIsNotNone(match)
            return set(match.group("names").split())

        self.assertEqual(shell_names("ALLOWED"), CONFIG.ALLOWED_NAMES)
        self.assertEqual(shell_names("BOOLEAN"), CONFIG.BOOLEAN_NAMES)
        self.assertEqual(shell_names("INTEGER"), set(CONFIG.INTEGER_RANGES))
        self.assertEqual(shell_names("ARRAY"), CONFIG.ARRAY_NAMES)

    def test_node_migration_schema_matches_runtime_schema(self):
        node = os.environ.get("TESLAUSB_TEST_NODE") or shutil.which("node")
        if node is None:
            self.skipTest("node is unavailable")
        script = (
            "const tool=require(process.argv[1]);"
            "process.stdout.write(JSON.stringify(tool.declarativeSchema()));"
        )
        completed = subprocess.run(
            [node, "-e", script, str(NODE_TOOL_PATH)],
            check=True,
            capture_output=True,
            text=True,
        )
        schema = json.loads(completed.stdout)
        self.assertEqual(set(schema["booleanNames"]), CONFIG.BOOLEAN_NAMES)
        self.assertEqual(
            {name: tuple(bounds) for name, bounds in schema["integerRanges"].items()},
            CONFIG.INTEGER_RANGES,
        )
        self.assertEqual(set(schema["arrayNames"]), CONFIG.ARRAY_NAMES)
        self.assertEqual(set(schema["stringNames"]), CONFIG.STRING_NAMES)

    def test_cli_never_writes_secrets_in_validation_output(self):
        path = self.write_document(valid_document())
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = CONFIG.main(["validate", str(path)])
        self.assertEqual(result, 0)
        combined = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn("correct horse battery staple", combined)
        self.assertNotIn("literal $HOME", combined)

    def test_ble_accessor_returns_only_configured_vin(self):
        document = valid_document()
        document["variables"]["TESLA_BLE_VIN"] = "5YJ3E1EA7KF000001"
        document["variables"]["SENTRY_CASE"] = 1
        path = self.write_document(document)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = CONFIG.main(["get-ble-vin", str(path)])
        self.assertEqual(result, 0)
        self.assertEqual(stdout.getvalue(), "5YJ3E1EA7KF000001\n")
        self.assertNotIn("correct horse battery staple", stdout.getvalue() + stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
