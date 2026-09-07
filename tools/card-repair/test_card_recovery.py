"""Full installer recovery boundaries, confined to a private Linux chroot.

No host mounts/services are touched. RootFS and /teslausb aliases are real;
LinuxSystem is a recording fake. Run with sudo for the chroot cases.
"""

import io
import json
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import traceback
import unittest
from unittest import mock

import card_install as repair


class SimulatedPowerLoss(BaseException):
    pass


class FakeSystem:
    instances = []

    def __init__(self, fs):
        self.fs = fs
        self.events = []
        self.runtime_masked = False
        self.__class__.instances.append(self)

    def preflight(self, boot):
        self.events.append(("preflight", str(boot)))
        return ("/", False), (str(boot), False)

    def quiesce(self):
        self.runtime_masked = True
        self.events.append(("quiesce",))

    def acquire_installer_lock(self):
        self.events.append(("installer_lock",))

    def wait_for_startup(self, log):
        self.events.append(("wait_for_startup",))

    def lock_workers(self):
        self.events.append(("lock_workers",))

    def command(self, args, **kwargs):
        self.events.append(("command", tuple(args)))
        return ""

    def remount(self, target, writable):
        self.events.append(("remount", target, writable))

    def release(self):
        self.events.append(("release",))


@unittest.skipUnless(os.name == "posix" and hasattr(os, "chroot") and
                     getattr(os, "geteuid", lambda: 1)() == 0,
                     "Root Linux isolated full-installer test")
class FullRunRecoveryTests(unittest.TestCase):
    def in_chroot(self, scenario, *, dropin_directory=True):
        # Child-only chroot protects the CI host even if the installer regresses.
        with tempfile.TemporaryDirectory(prefix="teslausb-recovery-tests-", dir="/run") as directory:
            root = Path(directory)
            for name in ("root/bin", "etc/systemd/system", "boot/firmware",
                         "mutable/teslausb/manual-fixes", "backingfiles/snapshots", "run", "tmp"):
                (root / name).mkdir(parents=True, mode=0o755, exist_ok=True)
            (root / "tmp").chmod(0o1777)
            (root / "root").chmod(0o700)
            (root / "teslausb").symlink_to("/boot/firmware")
            if dropin_directory:
                (root / repair.DROPIN.lstrip("/")).parent.mkdir(mode=0o755)
            (root / "root/bin/old.sh").write_bytes(b"original-runtime\n")
            (root / "root/bin/old.sh").chmod(0o751)
            contents = {"old.sh": b"updated-runtime\n", "new.sh": b"new-helper\n",
                        "maintenance.conf": repair.DROPIN_DATA}
            entries = []
            for destination, member, original in (
                    ("/root/bin/old.sh", "old.sh", b"original-runtime\n"),
                    ("/root/bin/new.sh", "new.sh", None),
                    (repair.DROPIN, "maintenance.conf", None)):
                entries.append({"destination": destination, "member": member,
                                "sha256": repair.digest(contents[member]),
                                "mode": 0o644 if destination == repair.DROPIN else 0o755,
                                "allow_absent": original is None,
                                "allowed_sha256": [repair.digest(contents[member])] +
                                ([repair.digest(original)] if original is not None else [])})
            archive = io.BytesIO()
            with tarfile.open(fileobj=archive, mode="w", format=tarfile.USTAR_FORMAT) as stream:
                for entry in entries:
                    member = tarfile.TarInfo(entry["member"])
                    data = contents[entry["member"]]
                    member.size = len(data)
                    stream.addfile(member, io.BytesIO(data))
            raw = archive.getvalue()
            config = {"install_id": "boundarytest", "source_commit": "a" * 40,
                      "payload_name": "test-payload.tar", "payload_sha256": repair.digest(raw),
                      "entries": entries, "marker_name": "TEST_MAINTENANCE_APPLIED.json",
                      "log_name": "test-maintenance.log"}
            (root / "boot/firmware/test-payload.tar").write_bytes(raw)
            (root / "boot/firmware/run_once").write_bytes(b"controlled-test-trigger\n")
            receive, send = os.pipe()
            pid = os.fork()
            if pid == 0:
                os.close(receive)
                try:
                    os.chroot(root)
                    os.chdir("/")
                    FakeSystem.instances = []
                    with mock.patch.object(repair, "LinuxSystem", FakeSystem), \
                            mock.patch.object(repair.os, "sync"), \
                            mock.patch("sys.stdout", io.StringIO()), \
                            mock.patch("sys.stderr", io.StringIO()):
                        scenario(config)
                    os.write(send, b"OK")
                    os._exit(0)
                except BaseException:
                    message = traceback.format_exc().encode("utf-8", "replace")
                    os.write(send, message[:60000])
                    os._exit(1)
            os.close(send)
            chunks = []
            while True:
                chunk = os.read(receive, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
            os.close(receive)
            _, status = os.waitpid(pid, 0)
            self.assertEqual(status, 0, b"".join(chunks).decode("utf-8", "replace"))

    def assert_original(self):
        self.assertEqual(Path("/root/bin/old.sh").read_bytes(), b"original-runtime\n")
        self.assertEqual(stat.S_IMODE(Path("/root/bin/old.sh").stat().st_mode), 0o751)
        self.assertFalse(Path("/root/bin/new.sh").exists())

    def assert_installed(self, config, *, consumed=True):
        self.assertEqual(Path("/root/bin/old.sh").read_bytes(), b"updated-runtime\n")
        self.assertEqual(Path("/root/bin/new.sh").read_bytes(), b"new-helper\n")
        self.assertEqual(Path(repair.DROPIN).read_bytes(), repair.DROPIN_DATA)
        self.assertFalse(Path(repair.PENDING).exists())
        self.assertEqual(Path("/boot/firmware/run_once").exists(), not consumed)
        if consumed:
            marker = json.loads((Path("/boot/firmware") / config["marker_name"]).read_bytes())
            self.assertEqual(marker["source_commit"], config["source_commit"])
            self.assertFalse(marker["recordings_modified"])
            self.assertTrue(Path(marker["backup"], "completed.json").is_file())

    def test_real_boot_alias_success_commits_gate_before_marker_and_trigger(self):
        def scenario(config):
            events = []
            original_remove = repair.RootFS.remove_regular
            original_boot = repair.boot_atomic
            original_rename = os.rename

            def remove(fs, name, allowed):
                result = original_remove(fs, name, allowed)
                if name == repair.PENDING:
                    events.append("gate-cleared")
                return result

            def boot(path, data):
                if path.name == config["marker_name"]:
                    self.assertFalse(Path(repair.PENDING).exists())
                    events.append("success-marker")
                return original_boot(path, data)

            def rename(source, destination, **kwargs):
                if Path(source).name == "run_once":
                    self.assertFalse(Path(repair.PENDING).exists())
                    self.assertTrue((Path("/boot/firmware") / config["marker_name"]).is_file())
                    events.append("trigger-consumed")
                return original_rename(source, destination, **kwargs)

            with mock.patch.object(repair.RootFS, "remove_regular", remove), \
                    mock.patch.object(repair, "boot_atomic", boot), \
                    mock.patch.object(repair.os, "rename", rename):
                self.assertEqual(repair.run(config), 0)
            self.assert_installed(config)
            self.assertEqual(events, ["gate-cleared", "success-marker", "trigger-consumed"])
            system = FakeSystem.instances[-1]
            self.assertTrue(system.runtime_masked)
            self.assertEqual(system.events[-2:], [("remount", "/boot/firmware", False),
                                                 ("remount", "/", False)])
            self.assertFalse(any(event[0] == "command" and "start" in event[1]
                                 for event in system.events))
            names = [event[0] for event in system.events]
            self.assertLess(names.index("wait_for_startup"), names.index("quiesce"))
            self.assertLess(names.index("quiesce"), names.index("lock_workers"))
        self.in_chroot(scenario)

    def test_ordinary_failure_rolls_back_exact_original_and_preserves_prior_marker(self):
        def scenario(config):
            marker = Path("/boot/firmware") / config["marker_name"]
            marker.write_bytes(b"prior-success-marker\n")
            atomic = repair.RootFS.atomic
            failed = False

            def fail_after_new(fs, name, data, *args, **kwargs):
                nonlocal failed
                result = atomic(fs, name, data, *args, **kwargs)
                if name == "/root/bin/new.sh" and not failed:
                    failed = True
                    raise OSError("injected runtime install failure")
                return result

            with mock.patch.object(repair.RootFS, "atomic", fail_after_new), \
                    self.assertRaisesRegex(OSError, "injected runtime"):
                repair.run(config)
            self.assert_original()
            self.assertEqual(marker.read_bytes(), b"prior-success-marker\n")
            self.assertFalse(Path(repair.PENDING).exists())
            self.assertTrue(Path("/boot/firmware/run_once").is_file())
            self.assertIn("rolled back", Path("/boot/firmware/test-maintenance.log").read_text())
        self.in_chroot(scenario)

    def test_interrupted_first_journal_with_missing_dropin_parent_is_recoverable(self):
        def scenario(config):
            atomic = repair.RootFS.atomic

            def fail_after_journal(fs, name, data, *args, **kwargs):
                result = atomic(fs, name, data, *args, **kwargs)
                if name == repair.PENDING and json.loads(data)["phase"] == "prepared":
                    raise SimulatedPowerLoss()
                return result

            with mock.patch.object(repair.RootFS, "atomic", fail_after_journal), \
                    self.assertRaises(SimulatedPowerLoss):
                repair.run(config)
            self.assert_original()
            self.assertTrue(Path(repair.PENDING).is_file())
            self.assertEqual(repair.run(config), 0)
            self.assert_installed(config)
        self.in_chroot(scenario, dropin_directory=False)

    def test_power_loss_at_every_install_boundary_retries_without_lost_trigger(self):
        for boundary in ("dropin", "old-file", "new-file", "installed-journal", "gate-cleared", "marker"):
            with self.subTest(boundary=boundary):
                def scenario(config):
                    atomic = repair.RootFS.atomic
                    remove = repair.RootFS.remove_regular
                    boot = repair.boot_atomic

                    def after_atomic(fs, name, data, *args, **kwargs):
                        result = atomic(fs, name, data, *args, **kwargs)
                        if ((boundary == "dropin" and name == repair.DROPIN) or
                                (boundary == "old-file" and name == "/root/bin/old.sh") or
                                (boundary == "new-file" and name == "/root/bin/new.sh") or
                                (boundary == "installed-journal" and name == repair.PENDING and
                                 json.loads(data)["phase"] == "installed")):
                            raise SimulatedPowerLoss()
                        return result

                    def after_remove(fs, name, allowed):
                        result = remove(fs, name, allowed)
                        if boundary == "gate-cleared" and name == repair.PENDING:
                            raise SimulatedPowerLoss()
                        return result

                    def after_boot(path, data):
                        result = boot(path, data)
                        if boundary == "marker" and path.name == config["marker_name"]:
                            raise SimulatedPowerLoss()
                        return result

                    with mock.patch.object(repair.RootFS, "atomic", after_atomic), \
                            mock.patch.object(repair.RootFS, "remove_regular", after_remove), \
                            mock.patch.object(repair, "boot_atomic", after_boot), \
                            self.assertRaises(SimulatedPowerLoss):
                        repair.run(config)
                    self.assertTrue(Path("/boot/firmware/run_once").is_file())
                    if boundary not in {"gate-cleared", "marker"}:
                        self.assertTrue(Path(repair.PENDING).is_file())
                        self.assertEqual(Path(repair.DROPIN).read_bytes(), repair.DROPIN_DATA)
                    self.assertEqual(repair.run(config), 0)
                    self.assert_installed(config)
                self.in_chroot(scenario)

    def test_failed_success_marker_preserves_committed_install_and_retry_hook(self):
        def scenario(config):
            original_boot = repair.boot_atomic

            def fail_marker(path, data):
                if path.name == config["marker_name"]:
                    raise OSError("injected marker write failure")
                return original_boot(path, data)

            with mock.patch.object(repair, "boot_atomic", fail_marker), \
                    self.assertRaisesRegex(OSError, "injected marker"):
                repair.run(config)
            self.assert_installed(config, consumed=False)
            self.assertEqual(repair.run(config), 0)
            self.assert_installed(config)
        self.in_chroot(scenario)

    def test_failed_trigger_rename_does_not_undo_committed_install(self):
        def scenario(config):
            original_rename = os.rename

            def fail_rename(source, destination, **kwargs):
                if Path(source).name == "run_once":
                    raise OSError("injected trigger rename failure")
                return original_rename(source, destination, **kwargs)

            with mock.patch.object(repair.os, "rename", fail_rename), \
                    self.assertRaisesRegex(OSError, "injected trigger"):
                repair.run(config)
            self.assert_installed(config, consumed=False)
            self.assertEqual(repair.run(config), 0)
            self.assert_installed(config)
        self.in_chroot(scenario)

    def test_unknown_runtime_fails_preflight_without_stopping_service(self):
        def scenario(config):
            Path("/root/bin/old.sh").write_bytes(b"unrelated-customization")
            with self.assertRaisesRegex(repair.RepairError, "Unknown customized"):
                repair.run(config)
            self.assertEqual(Path("/root/bin/old.sh").read_bytes(), b"unrelated-customization")
            self.assertTrue(Path("/boot/firmware/run_once").exists())
            self.assertFalse(Path(repair.PENDING).exists())
            self.assertFalse(FakeSystem.instances[-1].runtime_masked)
        self.in_chroot(scenario)

    def test_unsafe_boot_alias_is_rejected_before_payload_or_service_changes(self):
        def scenario(config):
            Path("/teslausb").unlink()
            Path("/teslausb").symlink_to("/root")
            with self.assertRaisesRegex(repair.RepairError, "boot alias"):
                repair.run(config)
            self.assert_original()
            self.assertTrue(Path("/boot/firmware/run_once").exists())
            self.assertEqual(FakeSystem.instances[-1].events, [])
        self.in_chroot(scenario)


class ResidualMountSafetyTests(unittest.TestCase):
    def setUp(self):
        self.system = repair.LinuxSystem(repair.RootFS())
        self.command = mock.patch.object(self.system, "command").start()
        self.host = mock.patch.object(self.system, "ensure_no_data_host").start()
        self.mounts = mock.patch.object(self.system, "live_mounts").start()
        self.addCleanup(mock.patch.stopall)
        self.cam = {"target": "/mnt/cam", "source": "/dev/loop7p1", "fstype": "vfat", "options": "ro,relatime"}

    def test_verified_image_uses_only_ordinary_unmount_and_rechecks(self):
        self.mounts.side_effect = [{"/mnt/cam": self.cam}, {}]
        self.command.side_effect = ["/backingfiles/cam_disk.bin", ""]
        self.system.clean_residual_live_mounts()
        self.assertEqual([call.args[0] for call in self.command.call_args_list], [
            ["losetup", "--list", "--noheadings", "--output", "BACK-FILE", "/dev/loop7"],
            ["umount", "--", "/mnt/cam"]])
        self.assertEqual(self.mounts.call_count, 2)
        self.host.assert_called_once()

    def test_entire_set_is_verified_before_first_unmount(self):
        music = dict(self.cam, target="/mnt/music", source="/dev/loop8")
        self.mounts.return_value = {"/mnt/cam": self.cam, "/mnt/music": music}
        self.command.side_effect = ["/backingfiles/cam_disk.bin", "/backingfiles/unrelated.bin"]
        with self.assertRaisesRegex(repair.RepairError, "backing file"):
            self.system.clean_residual_live_mounts()
        self.assertFalse(any(call.args[0][0] == "umount" for call in self.command.call_args_list))

    def test_non_loop_bind_overlay_and_unknown_filesystem_are_never_unmounted(self):
        for changes in ({"source": "/dev/sda1"}, {"source": "/dev/loop7[/another/path]"},
                        {"source": "/dev/loop7;anything"}, {"fstype": "overlay"}, {"fstype": "ext4"}):
            with self.subTest(changes=changes):
                self.command.reset_mock()
                self.mounts.return_value = {"/mnt/cam": dict(self.cam, **changes)}
                with self.assertRaisesRegex(repair.RepairError, "Unknown live"):
                    self.system.clean_residual_live_mounts()
                self.command.assert_not_called()

    def test_busy_unmount_is_not_retried_forced_or_lazy(self):
        self.mounts.return_value = {"/mnt/cam": self.cam}
        self.command.side_effect = ["/backingfiles/cam_disk.bin", repair.RepairError("busy")]
        with self.assertRaisesRegex(repair.RepairError, "busy"):
            self.system.clean_residual_live_mounts()
        self.assertEqual(self.command.call_count, 2)
        self.assertEqual(self.command.call_args.args[0], ["umount", "--", "/mnt/cam"])

    def test_successful_command_does_not_replace_mount_disappearance_check(self):
        self.mounts.return_value = {"/mnt/cam": self.cam}
        self.command.side_effect = ["/backingfiles/cam_disk.bin", ""]
        with self.assertRaisesRegex(repair.RepairError, "remains mounted"):
            self.system.clean_residual_live_mounts()

    def test_connected_host_prevents_even_loop_inspection(self):
        self.host.side_effect = repair.RepairError("USB host attached")
        with self.assertRaisesRegex(repair.RepairError, "USB host"):
            self.system.clean_residual_live_mounts()
        self.mounts.assert_not_called()
        self.command.assert_not_called()


class MountInventorySafetyTests(unittest.TestCase):
    def test_nested_and_duplicate_live_mounts_are_rejected(self):
        system = repair.LinuxSystem(repair.RootFS())
        for rows in ([{"target": "/"}, {"target": "/mnt/cam/unknown"}],
                     [{"target": "/"}, {"target": "/mnt/cam"}, {"target": "/mnt/cam"}]):
            with self.subTest(rows=rows), \
                    mock.patch.object(system, "command", return_value=json.dumps({"filesystems": rows})), \
                    self.assertRaisesRegex(repair.RepairError, "nested|Duplicate"):
                system.live_mounts()

    def test_empty_or_unrecognized_mount_inventory_fails_closed(self):
        system = repair.LinuxSystem(repair.RootFS())
        for value in ({}, {"filesystems": []}, {"filesystems": "unexpected"}):
            with self.subTest(value=value), \
                    mock.patch.object(system, "command", return_value=json.dumps(value)), \
                    self.assertRaises(repair.RepairError):
                system.live_mounts()


if __name__ == "__main__":
    unittest.main()
