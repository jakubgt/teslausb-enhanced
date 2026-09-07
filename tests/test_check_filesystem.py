import contextlib
import errno
import importlib.util
import pathlib
import os
import signal
import stat
import subprocess
import sys
import types
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_filesystem", ROOT / "run/check-filesystem.py")
fs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fs)


def result(status=0, output=""):
    return subprocess.CompletedProcess([], status, output)


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.log = mock.patch.object(fs, "log").start()
        mock.patch.object(fs, "related_loop_devices", return_value={"7:1"}).start()
        self.addCleanup(mock.patch.stopall)

    def check(self, statuses, read_only=False, kind="vfat"):
        with mock.patch.object(fs, "validate_target", return_value=(7, 1)) as validate, \
                mock.patch.object(fs, "require_command", return_value=kind), \
                mock.patch.object(fs, "command", side_effect=[result(s) for s in statuses]) as run:
            try:
                fs.perform_check("/dev/loop0p1", read_only)
            finally:
                self.calls = run.call_args_list
                self.validations = validate.call_args_list

    def test_clean_read_only_check_never_repairs(self):
        self.check([0])
        self.assertEqual(1, len(self.calls))
        self.assertEqual(["/sbin/fsck.vfat", "-n", "/dev/loop0p1"], self.calls[0].args[0])
        self.assertEqual({"timeout": None, "capture": False}, self.calls[0].kwargs)
        self.assertEqual(2, len(self.validations))

    def test_repair_requires_a_separate_clean_verification(self):
        for repair_status in (0, 1):
            self.check([1, repair_status, 0])
            self.assertEqual(["-n", "-p", "-n"], [call.args[0][1] for call in self.calls])
            self.assertEqual(4, len(self.validations))

    def test_read_only_nonclean_never_repairs(self):
        with self.assertRaises(fs.CheckError):
            self.check([1], read_only=True)
        self.assertEqual(1, len(self.calls))

    def test_abnormal_checker_exit_never_triggers_repair(self):
        for status in (-9, -15, 2, 8, 16, 69, 137):
            with self.subTest(status=status), self.assertRaises(fs.CheckError):
                self.check([status])
            self.assertEqual(1, len(self.calls))

    def test_failed_repair_or_verification_is_not_success(self):
        for statuses in ([1, -9], [1, 8], [1, 1, 1], [1, 0, -9]):
            with self.subTest(statuses=statuses), self.assertRaises(fs.CheckError):
                self.check(statuses)

    def test_exfat_uses_its_own_checker(self):
        self.check([4, 1, 0], kind="exfat")
        self.assertTrue(all(call.args[0][0] == "/sbin/fsck.exfat" for call in self.calls))

    def test_exfat_nonrepairable_status_is_not_ignored(self):
        for status in (1, 2, 8, -9):
            with self.assertRaises(fs.CheckError):
                self.check([status], kind="exfat")
            self.assertEqual(1, len(self.calls))

    def test_exfat_read_only_nonclean_does_not_repair(self):
        with self.assertRaises(fs.CheckError):
            self.check([4], read_only=True, kind="exfat")
        self.assertEqual(1, len(self.calls))

    def test_unknown_filesystem_never_runs_checker(self):
        with self.assertRaises(fs.CheckError):
            self.check([], kind="ext4")
        self.assertEqual([], self.calls)

    def test_interruption_before_check_prevents_commands(self):
        with mock.patch.object(fs, "validate_target"), \
                mock.patch.object(fs, "require_command", return_value="vfat"), \
                mock.patch.object(fs, "command") as command, self.assertRaises(fs.CheckError):
            fs.perform_check("/dev/loop0p1", interrupted=lambda: True)
        command.assert_not_called()

    def test_command_setup_has_deadline_but_checker_can_stream_without_one(self):
        with mock.patch.object(fs.subprocess, "run", return_value=result()) as run:
            fs.command(["/sbin/swapon", "/dev/zram7"])
            self.assertEqual(30, run.call_args.kwargs["timeout"])
            fs.command(["/sbin/fsck.vfat", "-p", "/dev/loop0p1"], timeout=None, capture=False)
            self.assertIsNone(run.call_args.kwargs["timeout"])
            self.assertIsNone(run.call_args.kwargs["stdout"])
            self.assertIsNone(run.call_args.kwargs["stderr"])

    def test_setup_timeout_and_nonzero_are_errors(self):
        with mock.patch.object(fs.subprocess, "run", side_effect=subprocess.TimeoutExpired("swapon", 30)):
            with self.assertRaises(fs.CheckError):
                fs.command(["/sbin/swapon"])
        with mock.patch.object(fs, "command", return_value=result(1, "failed")):
            with self.assertRaises(fs.CheckError):
                fs.require_command(["/sbin/swapon"])

    def test_only_explicit_loop_partitions_are_accepted(self):
        for target in ("/dev/sda1", "/dev/mmcblk0p3", "/dev/loop0", "/dev/loop0p0",
                       "/dev/loop0p1/../sda1", "--help", "/tmp/loop0p1"):
            with self.subTest(target=target), self.assertRaises(fs.CheckError):
                fs.validate_target(target)

    def test_target_symlink_and_regular_file_rejected(self):
        for mode in (stat.S_IFLNK, stat.S_IFREG, stat.S_IFIFO):
            info = types.SimpleNamespace(st_mode=mode | 0o600, st_uid=0)
            with mock.patch.object(pathlib.Path, "lstat", return_value=info), self.assertRaises(fs.CheckError):
                fs.block_identity("/dev/loop0p1")

    def test_mounted_target_rejected_by_device_number_not_mount_name(self):
        table = "41 24 7:1 / /unusual/mount rw - vfat /different/device rw\n"
        with mock.patch.object(pathlib.Path, "resolve", return_value=pathlib.Path("/dev")), \
                mock.patch.object(fs, "block_identity", return_value=(7, 1)), \
                mock.patch.object(pathlib.Path, "read_text", return_value=table), \
                self.assertRaisesRegex(fs.CheckError, "mounted"):
            fs.validate_target("/dev/loop0p1")

    def test_device_change_and_malformed_mountinfo_rejected(self):
        with mock.patch.object(pathlib.Path, "resolve", return_value=pathlib.Path("/dev")), \
                mock.patch.object(fs, "block_identity", return_value=(7, 1)), \
                mock.patch.object(pathlib.Path, "read_text", return_value="malformed"):
            with self.assertRaisesRegex(fs.CheckError, "changed"):
                fs.validate_target("/dev/loop0p1", (7, 2))
            with self.assertRaisesRegex(fs.CheckError, "parse"):
                fs.validate_target("/dev/loop0p1")

    def test_empty_mount_table_fails_closed(self):
        with mock.patch.object(pathlib.Path, "resolve", return_value=pathlib.Path("/dev")), \
                mock.patch.object(fs, "block_identity", return_value=(7, 1)), \
                mock.patch.object(pathlib.Path, "read_text", return_value=""), self.assertRaises(fs.CheckError):
            fs.validate_target("/dev/loop0p1")

    def test_memory_requires_explicit_memtotal(self):
        with mock.patch.object(pathlib.Path, "read_text", return_value="MemTotal: 424960 kB\n"):
            self.assertEqual(415 * fs.MIB, fs.memory_total())
        for value in ("", "MemTotal: 0 kB", "MemTotal: nope kB"):
            with mock.patch.object(pathlib.Path, "read_text", return_value=value), self.assertRaises(fs.CheckError):
                fs.memory_total()

    def test_small_pi_requires_zram_before_check_and_always_cleans_up(self):
        for failure in ("prepare", "check", None):
            with mock.patch.object(fs.os, "geteuid", return_value=0, create=True), \
                    mock.patch.object(fs, "exclusive_check", return_value=contextlib.nullcontext()), \
                    mock.patch.object(fs, "validate_target"), \
                    mock.patch.object(fs, "memory_total", return_value=415 * fs.MIB), \
                    mock.patch.object(fs, "TemporaryZram") as zram, \
                    mock.patch.object(fs, "perform_check") as check:
                if failure == "prepare":
                    zram.return_value.prepare.side_effect = fs.CheckError("no zram")
                if failure == "check":
                    check.side_effect = fs.CheckError("not clean")
                if failure:
                    with self.assertRaises(fs.CheckError):
                        fs.run("/dev/loop0p1")
                else:
                    fs.run("/dev/loop0p1")
                zram.return_value.cleanup.assert_called_once()
                if failure == "prepare":
                    check.assert_not_called()

    def test_large_machine_does_not_create_zram(self):
        with mock.patch.object(fs.os, "geteuid", return_value=0, create=True), \
                mock.patch.object(fs, "exclusive_check", return_value=contextlib.nullcontext()), \
                mock.patch.object(fs, "validate_target"), \
                mock.patch.object(fs, "memory_total", return_value=2048 * fs.MIB), \
                mock.patch.object(fs, "TemporaryZram") as zram, \
                mock.patch.object(fs, "perform_check"):
            fs.run("/dev/loop0p1")
            zram.return_value.prepare.assert_not_called()

    def test_root_required_before_any_device_operation(self):
        with mock.patch.object(fs.os, "geteuid", return_value=1000, create=True), \
                mock.patch.object(fs, "validate_target") as validate, self.assertRaises(fs.CheckError):
            fs.run("/dev/loop0p1")
        validate.assert_not_called()

    def test_main_returns_69_for_setup_check_or_cleanup_failure(self):
        with mock.patch.object(fs, "run", side_effect=fs.CheckError("failure")):
            self.assertEqual(69, fs.main(["--read-only", "/dev/loop0p1"]))

    def test_new_zram_device_wait_is_bounded_and_retries_only_missing_nodes(self):
        with mock.patch.object(fs, "block_identity", side_effect=[FileNotFoundError(), (253, 7)]), \
                mock.patch.object(fs.time, "sleep") as sleep:
            self.assertEqual((253, 7), fs.wait_for_device("/dev/zram7"))
            sleep.assert_called_once_with(0.05)
        with mock.patch.object(fs, "block_identity", side_effect=FileNotFoundError()), \
                mock.patch.object(fs.time, "monotonic", side_effect=[0, 5]), self.assertRaises(fs.CheckError):
            fs.wait_for_device("/dev/zram7")


class AliasTests(unittest.TestCase):
    def test_mounted_alias_to_same_image_inode_is_rejected(self):
        base = pathlib.Path("/sys/block")
        loops = [base / name for name in ("loop7", "loop9", "loop10")]
        contents = {
            "/sys/block/loop7/loop/backing_file": "/backingfiles/cam.bin",
            "/sys/block/loop9/loop/backing_file": "/backingfiles/cam-hardlink.bin",
            "/sys/block/loop10/loop/backing_file": "/backingfiles/snapshot.bin",
            "/sys/block/loop7/dev": "7:7",
            "/sys/block/loop7/loop7p1/dev": "259:0",
            "/sys/block/loop9/dev": "7:9",
            "/sys/block/loop9/loop9p1/dev": "259:1",
            "/proc/self/mountinfo": "41 24 259:1 / /mnt/old rw - vfat /dev/loop9p1 rw\n",
        }

        def glob(path, pattern):
            return iter(loops if path == base else [path / (path.name + "p1")])

        def image_stat(path):
            return types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_dev=8,
                                         st_ino=99 if "snapshot" in str(path) else 42)

        with mock.patch.object(pathlib.Path, "glob", autospec=True, side_effect=glob), \
                mock.patch.object(pathlib.Path, "read_text", autospec=True,
                                  side_effect=lambda path: contents[str(path).replace("\\", "/")]), \
                mock.patch.object(fs.os, "stat", side_effect=image_stat), \
                mock.patch.object(fs, "block_identity", return_value=(259, 0)), \
                mock.patch.object(pathlib.Path, "resolve", return_value=pathlib.Path("/dev")):
            self.assertEqual({"7:7", "259:0", "7:9", "259:1"}, fs.related_loop_devices("/dev/loop7p1"))
            with self.assertRaisesRegex(fs.CheckError, "alias is mounted"):
                fs.validate_target("/dev/loop7p1")


@unittest.skipUnless(os.name == "posix", "requires Linux process-group signals")
class ProcessSignalTests(unittest.TestCase):
    def test_group_sigterm_is_reaped_before_cleanup_and_prevents_further_checks(self):
        script = r'''
import contextlib, importlib.util, os, pathlib, subprocess, sys
spec = importlib.util.spec_from_file_location("fs", sys.argv[1])
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)
fs.os.geteuid = lambda: 0
fs.exclusive_check = lambda: contextlib.nullcontext()
fs.validate_target = lambda *args: (7, 1)
fs.memory_total = lambda: 415 * fs.MIB
fs.require_command = lambda args: "vfat"
class Swap:
    def prepare(self, total): pass
    def cleanup(self): print("CLEANUP", flush=True)
fs.TemporaryZram = Swap
original = fs.command
stage = sys.argv[2]
def checker(args, **kwargs):
    print("CHECK " + args[1], flush=True)
    if args[1] != stage:
        return subprocess.CompletedProcess(args, 1, "")
    return original([sys.executable, "-c", "import time; print('READY', flush=True); time.sleep(60)"], **kwargs)
fs.command = checker
sys.exit(fs.main(["/dev/loop0p1"]))
'''
        for stage in ("-n", "-p"):
            with self.subTest(stage=stage):
                process = subprocess.Popen([sys.executable, "-c", script,
                                            str(ROOT / "run/check-filesystem.py"), stage],
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           text=True, start_new_session=True)
                seen = []
                try:
                    # This subprocess creates no real devices/files; its checker
                    # is only a sleeping Python process in an isolated group.
                    while True:
                        line = process.stdout.readline()
                        self.assertTrue(line, "fake checker exited before becoming ready")
                        seen.append(line)
                        if line.strip() == "READY":
                            break
                    os.killpg(process.pid, signal.SIGTERM)
                    output, _ = process.communicate(timeout=10)
                    output = "".join(seen) + output
                    self.assertEqual(69, process.returncode, output)
                    self.assertIn(stage + " returned -15", output)
                    self.assertLess(output.index("returned -15"), output.index("CLEANUP"))
                    self.assertNotIn("CHECK ", output.split("READY", 1)[1])
                    self.assertNotIn("filesystem verified clean", output)
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=10)


class ZramTests(unittest.TestCase):
    def setUp(self):
        self.active = False
        self.writes = []
        self.commands = []
        self.fail_command = None
        self.contents = {
            "/sys/class/zram-control/hot_add": "7\n",
            "/sys/block/zram7/initstate": "0\n",
            "/sys/block/zram7/disksize": "0\n",
            "/sys/block/zram7/backing_dev": "none\n",
        }
        mock.patch.object(fs, "log").start()
        mock.patch.object(fs, "block_identity", return_value=(253, 7)).start()
        mock.patch.object(pathlib.Path, "read_text", autospec=True, side_effect=self.read).start()
        mock.patch.object(pathlib.Path, "write_text", autospec=True, side_effect=self.write).start()
        mock.patch.object(pathlib.Path, "exists", return_value=True).start()
        mock.patch.object(fs, "require_command", side_effect=self.command).start()
        self.addCleanup(mock.patch.stopall)
        self.zram = fs.TemporaryZram()

    @staticmethod
    def name(path):
        return str(path).replace("\\", "/")

    def read(self, path, *args, **kwargs):
        name = self.name(path)
        if name == "/proc/swaps":
            return "Filename Type Size Used Priority\n" + (
                "/dev/zram7 partition 524288 0 100\n" if self.active else "")
        return self.contents[name]

    def write(self, path, value, *args, **kwargs):
        name = self.name(path)
        if name.endswith("/reset") or name.endswith("/hot_remove"):
            self.assertFalse(self.active, "must never reset/remove active swap")
        self.writes.append((name, value))
        self.contents[name] = value

    def command(self, args):
        self.commands.append(args)
        if args[0].endswith("/swapon"):
            self.active = True
        if self.fail_command == args[0]:
            raise fs.CheckError("command failed or timed out")
        if args[0].endswith("/swapoff"):
            self.active = False
        return ""

    def test_only_owned_zram_is_initialized_and_removed(self):
        self.zram.prepare(415 * fs.MIB)
        self.assertIn(("/sys/block/zram7/disksize", str(512 * fs.MIB)), self.writes)
        expected_limit = (415 * fs.MIB // 4) // 4096 * 4096
        self.assertIn(("/sys/block/zram7/mem_limit", str(expected_limit)), self.writes)
        self.assertIn(["/sbin/mkswap", "/dev/zram7"], self.commands)
        self.zram.cleanup()
        self.assertIn(["/sbin/swapoff", "/dev/zram7"], self.commands)
        self.assertEqual(("/sys/class/zram-control/hot_remove", "7"), self.writes[-1])
        self.assertFalse(any("/dev/loop" in str(command) for command in self.commands))
        self.assertTrue(all(path.startswith("/sys/") for path, value in self.writes))

    def test_virtual_and_physical_size_are_bounded(self):
        self.zram.prepare(128 * fs.MIB)
        self.assertIn(("/sys/block/zram7/disksize", str(256 * fs.MIB)), self.writes)
        self.assertIn(("/sys/block/zram7/mem_limit", str(32 * fs.MIB)), self.writes)

    def test_initialized_or_disk_backed_device_is_not_modified(self):
        for path, value in (("initstate", "1"), ("disksize", "4096"), ("backing_dev", "/dev/sda1")):
            previous = self.contents["/sys/block/zram7/" + path]
            self.contents["/sys/block/zram7/" + path] = value
            with self.subTest(path=path), self.assertRaises(fs.CheckError):
                self.zram.prepare(415 * fs.MIB)
            self.zram.cleanup()
            self.assertEqual([], self.writes)
            self.assertNotIn(["/sbin/mkswap", "/dev/zram7"], self.commands)
            self.contents["/sys/block/zram7/" + path] = previous

    def test_failed_mkswap_cleans_only_inactive_owned_device(self):
        self.fail_command = "/sbin/mkswap"
        with self.assertRaises(fs.CheckError):
            self.zram.prepare(415 * fs.MIB)
        self.zram.cleanup()
        self.assertNotIn(["/sbin/swapoff", "/dev/zram7"], self.commands)
        self.assertEqual(("/sys/class/zram-control/hot_remove", "7"), self.writes[-1])

    def test_timed_out_swapon_that_activated_is_safely_deactivated(self):
        self.fail_command = "/sbin/swapon"
        with self.assertRaises(fs.CheckError):
            self.zram.prepare(415 * fs.MIB)
        self.assertTrue(self.active)
        self.zram.cleanup()
        self.assertIn(["/sbin/swapoff", "/dev/zram7"], self.commands)

    def test_failed_swapoff_never_resets_or_removes(self):
        self.zram.prepare(415 * fs.MIB)
        self.fail_command = "/sbin/swapoff"
        with self.assertRaises(fs.CheckError):
            self.zram.cleanup()
        self.assertTrue(self.active)
        self.assertFalse(any(path.endswith(("/reset", "/hot_remove")) for path, value in self.writes))

    def test_invalid_hot_add_response_never_formats_anything(self):
        for number in ("../sda", "7 extra", "-1", ""):
            self.contents["/sys/class/zram-control/hot_add"] = number
            with self.assertRaises(fs.CheckError):
                self.zram.prepare(415 * fs.MIB)
        self.assertFalse(any(command[0] == "/sbin/mkswap" for command in self.commands))

    def test_unexpectedly_active_new_device_is_not_touched(self):
        self.active = True
        with self.assertRaises(fs.CheckError):
            self.zram.prepare(415 * fs.MIB)
        self.zram.cleanup()
        self.assertEqual([], self.writes)
        self.assertEqual([["/sbin/modprobe", "zram", "num_devices=0"]], self.commands)

    def test_swapoff_success_but_still_active_never_resets(self):
        self.zram.prepare(415 * fs.MIB)
        with mock.patch.object(fs, "require_command", return_value=""), self.assertRaises(fs.CheckError):
            self.zram.cleanup()
        self.assertFalse(any(path.endswith(("/reset", "/hot_remove")) for path, value in self.writes))

    def test_changed_zram_identity_is_not_cleaned(self):
        self.zram.prepare(415 * fs.MIB)
        with mock.patch.object(fs, "block_identity", return_value=(253, 8)), self.assertRaises(fs.CheckError):
            self.zram.cleanup()
        self.assertNotIn(["/sbin/swapoff", "/dev/zram7"], self.commands)

    def test_busy_reset_and_hot_remove_retry_then_succeed(self):
        self.zram.prepare(415 * fs.MIB)
        attempts = {"reset": 0, "hot_remove": 0}

        def busy_twice(path, value):
            if path.name in attempts:
                attempts[path.name] += 1
                if attempts[path.name] <= 2:
                    raise OSError(errno.EBUSY, "temporary scanner")
            return self.write(path, value)

        with mock.patch.object(pathlib.Path, "write_text", new=busy_twice), \
                mock.patch.object(fs.time, "sleep") as sleep, \
                mock.patch.object(fs, "block_identity", return_value=(253, 7)) as identity, \
                mock.patch.object(self.zram, "active", wraps=self.zram.active) as active:
            self.zram.cleanup()
        self.assertEqual({"reset": 3, "hot_remove": 3}, attempts)
        self.assertEqual(4, sleep.call_count)
        self.assertGreaterEqual(identity.call_count, 7)
        self.assertGreaterEqual(active.call_count, 8)
        self.assertIsNone(self.zram.device)

    def test_busy_hot_remove_timeout_leaves_inactive_device_and_fails(self):
        self.zram.prepare(415 * fs.MIB)

        def always_busy(path, value):
            if path.name == "hot_remove":
                raise OSError(errno.EBUSY, "held open")
            return self.write(path, value)

        with mock.patch.object(pathlib.Path, "write_text", new=always_busy), \
                mock.patch.object(fs.time, "monotonic", side_effect=[0, 10]), \
                mock.patch.object(fs.time, "sleep") as sleep, \
                self.assertRaisesRegex(fs.CheckError, "remained busy at hot_remove"):
            self.zram.cleanup()
        self.assertFalse(self.active)
        self.assertEqual("/dev/zram7", self.zram.device)
        self.assertIn(("/sys/block/zram7/reset", "1"), self.writes)
        self.assertFalse(any(path.endswith("/hot_remove") for path, value in self.writes))
        sleep.assert_not_called()

    def test_busy_reset_timeout_never_attempts_hot_remove(self):
        self.zram.prepare(415 * fs.MIB)
        with mock.patch.object(pathlib.Path, "write_text", side_effect=OSError(errno.EBUSY, "held open")) as write, \
                mock.patch.object(fs.time, "monotonic", side_effect=[0, 10]), \
                self.assertRaisesRegex(fs.CheckError, "remained busy at reset"):
            self.zram.cleanup()
        self.assertFalse(self.active)
        write.assert_called_once_with("1")

    def test_cleanup_retry_refuses_changed_identity_or_active_swap(self):
        self.zram.prepare(415 * fs.MIB)
        self.active = False
        for become_active in (False, True):
            with self.subTest(become_active=become_active), \
                    mock.patch.object(pathlib.Path, "write_text", side_effect=OSError(errno.EBUSY, "scanner")) as write, \
                    mock.patch.object(fs.time, "sleep"), \
                    mock.patch.object(fs.time, "monotonic", return_value=0), \
                    mock.patch.object(fs, "block_identity", side_effect=[(253, 7), (253, 7) if become_active else (253, 8)]), \
                    mock.patch.object(self.zram, "active", side_effect=[False, True] if become_active else [False]), \
                    self.assertRaisesRegex(fs.CheckError, "refusing cleanup retry"):
                self.zram.inactive_write(self.zram.directory / "reset", "1", 10)
            write.assert_called_once_with("1")

    def test_cleanup_does_not_retry_nonbusy_errors(self):
        self.zram.prepare(415 * fs.MIB)
        with mock.patch.object(pathlib.Path, "write_text", side_effect=OSError(errno.EIO, "I/O error")) as write, \
                mock.patch.object(fs.time, "sleep") as sleep, self.assertRaises(OSError):
            self.zram.cleanup()
        write.assert_called_once_with("1")
        sleep.assert_not_called()


class LockTests(unittest.TestCase):
    def setUp(self):
        self.directory_info = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o700, st_uid=0)
        self.file_info = types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_nlink=1)
        self.fcntl = types.SimpleNamespace(flock=mock.Mock(), LOCK_EX=2)
        mock.patch.dict(sys.modules, {"fcntl": self.fcntl}).start()
        mock.patch.object(pathlib.Path, "mkdir").start()
        mock.patch.object(pathlib.Path, "lstat", side_effect=lambda: self.directory_info).start()
        mock.patch.object(pathlib.Path, "resolve", return_value=fs.RUNTIME.absolute()).start()
        self.open = mock.patch.object(fs.os, "open", return_value=71).start()
        self.close = mock.patch.object(fs.os, "close").start()
        mock.patch.object(fs.os, "fstat", side_effect=lambda fd: self.file_info).start()
        for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_NONBLOCK"):
            if not hasattr(fs.os, name):
                mock.patch.object(fs.os, name, 1, create=True).start()
        self.addCleanup(mock.patch.stopall)

    def test_lock_is_exclusive_and_descriptor_closes_after_exception(self):
        with self.assertRaises(RuntimeError):
            with fs.exclusive_check():
                self.fcntl.flock.assert_called_once_with(71, self.fcntl.LOCK_EX)
                raise RuntimeError("test")
        self.close.assert_called_once_with(71)
        self.assertEqual(0o600, self.open.call_args.args[2])

    def test_nonprivate_directory_fails_before_open(self):
        self.directory_info.st_mode = stat.S_IFDIR | 0o755
        with self.assertRaises(fs.CheckError), fs.exclusive_check():
            self.fail("unsafe directory accepted")
        self.open.assert_not_called()

    def test_symlink_directory_fails_before_open(self):
        with mock.patch.object(pathlib.Path, "resolve", return_value=pathlib.Path("/elsewhere")), \
                self.assertRaises(fs.CheckError), fs.exclusive_check():
            self.fail("symlink directory accepted")
        self.open.assert_not_called()

    def test_invalid_lock_file_is_not_used(self):
        for attribute, value in (("st_mode", stat.S_IFREG | 0o644), ("st_uid", 1000), ("st_nlink", 2)):
            previous = getattr(self.file_info, attribute)
            setattr(self.file_info, attribute, value)
            with self.subTest(attribute=attribute), self.assertRaises(fs.CheckError), fs.exclusive_check():
                self.fail("unsafe file accepted")
            setattr(self.file_info, attribute, previous)
        self.fcntl.flock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
