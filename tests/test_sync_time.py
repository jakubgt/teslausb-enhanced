import contextlib
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("teslausb_sync_time", REPO_ROOT / "run/sync-time.py")
clock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clock)
NOW = 1788544800


def result(text="", status=0):
    return subprocess.CompletedProcess([], status, text, "")


def reply(adjusted=False, **changes):
    value = {"time": clock.utc(NOW), "stratum": 2, "leap": "no-leap",
             "adjusted": adjusted, "offset": 100.0}
    value.update(changes)
    return result(json.dumps(value))


class StopLoop(Exception):
    pass


class ClockTests(unittest.TestCase):
    def setUp(self):
        self.worker = clock.ClockWorker()
        self.worker.log = mock.Mock()

    def test_ntp_reply_rejects_untrusted_or_invalid_success_reports(self):
        self.assertEqual(NOW, clock.valid_ntp_reply(reply()))
        self.assertEqual(NOW, clock.valid_ntp_reply(reply(True), adjusted=True))
        self.assertEqual(NOW, clock.valid_ntp_reply(reply(leap="noleap")))
        for invalid in (None, result("{}"), result("not json"), result("[]"),
                        reply(stratum=0), reply(stratum=16), reply(stratum=True),
                        reply(leap="unsync"), reply(offset=float("nan")),
                        reply(offset=True), reply(time="broken"),
                        reply(time="2026-09-04T00:00:00"),
                        reply(time="1970-01-01T00:00:00+00:00"),
                        reply(adjusted=True), result(reply().stdout, status=1)):
            with self.subTest(invalid=invalid):
                self.assertIsNone(clock.valid_ntp_reply(invalid))

    def test_archiveloop_launches_once_in_background_before_camera_or_archive_wait(self):
        source = (REPO_ROOT / "run/archiveloop").read_text(encoding="utf-8")
        startup = source[source.index('log "Starting archiveloop at '):]
        launch = re.search(
            r"(?m)^/usr/bin/python3 /root/bin/sync-time\.py 2>&1\s*\|\s*"
            r"while IFS= read -r clock_line\s*do\s*log \"\$clock_line\"\s*done\s*&\s*$",
            startup,
        )
        self.assertIsNotNone(launch, "clock worker must run asynchronously through the rotating logger")
        self.assertEqual(1, source.count("/root/bin/sync-time.py"))
        self.assertLess(launch.start(), startup.index("\nif has_cam_disk"))
        self.assertLess(launch.start(), startup.index("wait_for_archive_to_be_reachable"))
        self.assertNotRegex(source, r"(?m)^\s*(?:function\s+)?set_time(?:\s|\(|$)")

    def test_service_stop_signals_clock_worker_to_restore_paused_ntp(self):
        configure = (REPO_ROOT / "setup/pi/configure.sh").read_text(encoding="utf-8")
        service = configure.split("cat << EOF > /lib/systemd/system/teslausb.service", 1)[1].split("\nEOF", 1)[0]
        self.assertIn("\nKillMode=control-group\n", service)
        self.assertNotIn("KillMode=mixed", service)
        self.assertIn("TimeoutStopSec=30s", service)

    def test_worker_log_leaves_timestamp_and_file_rotation_to_parent(self):
        with mock.patch("builtins.print") as output:
            clock.ClockWorker().log("test")
        output.assert_called_once_with("clock: test", flush=True)
        with mock.patch("builtins.print", side_effect=BrokenPipeError):
            clock.ClockWorker().log("logger already stopped; restoration must continue")

    def test_every_external_command_has_a_deadline(self):
        with mock.patch.object(clock.subprocess, "run", side_effect=subprocess.TimeoutExpired("ntpq", 5)) as run:
            self.assertIsNone(clock.command(["ntpq"]))
            self.assertEqual(5, run.call_args.kwargs["timeout"])
            self.assertFalse(run.call_args.kwargs["check"])

    def test_ntpd_requires_network_sync_and_valid_leap_and_stratum(self):
        cases = [("status=0615 leap_none, sync_ntp, leap=00, stratum=2", True),
                 ("sync_ntp, leap=01, stratum=3", True),
                 ("sync_local, leap=00, stratum=2", False),
                 ("sync_ntp, leap=11, stratum=16", False),
                 ("sync_ntp, leap=00, stratum=0", False),
                 ("sync_ntp, leap=000, stratum=2", False),
                 ("", False)]
        for output, expected in cases:
            with self.subTest(output=output), mock.patch.object(clock, "command", return_value=result(output)):
                self.assertEqual(expected, self.worker.daemon_synced())

    def test_already_synchronized_clock_does_not_step_or_stop_ntpd(self):
        with mock.patch.object(self.worker, "daemon_synced", return_value=True), \
                mock.patch.object(clock.time, "time", return_value=NOW), \
                mock.patch.object(clock, "command") as run:
            self.assertEqual("ntpd", self.worker.sync_once())
            run.assert_not_called()

    def test_offline_does_not_stop_ntpd(self):
        with mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                mock.patch.object(clock, "command", return_value=None) as run:
            self.assertIsNone(self.worker.sync_once())
            self.assertEqual(["ntpdig", "ntpdig"], [call.args[0][0] for call in run.call_args_list])
            self.assertTrue(all(call.kwargs["timeout"] == 15 for call in run.call_args_list))

    def test_offline_then_online_retries_even_without_archive(self):
        with mock.patch.dict(os.environ, {"ARCHIVE_SYSTEM": "none"}), \
                mock.patch.object(self.worker, "restore_fallback"), \
                mock.patch.object(self.worker, "sync_once", side_effect=[None, None, "ntpd"]), \
                mock.patch.object(clock.time, "time", return_value=NOW), \
                mock.patch.object(clock.time, "sleep", side_effect=[None, None, StopLoop]) as sleep, \
                mock.patch.object(clock, "read_state", side_effect=FileNotFoundError), \
                mock.patch.object(clock, "write_state") as write:
            with self.assertRaises(StopLoop):
                self.worker.run()
            self.assertEqual([30, 60, 3600], [call.args[0] for call in sleep.call_args_list])
            statuses = [call.args[2]["state"] for call in write.call_args_list if call.args[1] == "status.json"]
            self.assertEqual(["waiting_for_network_time", "waiting_for_network_time", "synchronized"], statuses)
            saved = [call for call in write.call_args_list if call.args[1] == "last-sync.json"]
            self.assertEqual(1, len(saved))
            self.assertEqual(NOW, saved[0].args[2]["epoch"])

    def test_offline_backoff_is_capped_and_never_persists_unverified_time(self):
        with mock.patch.object(self.worker, "restore_fallback"), \
                mock.patch.object(self.worker, "sync_once", return_value=None), \
                mock.patch.object(clock.time, "sleep", side_effect=[None] * 6 + [StopLoop]) as sleep, \
                mock.patch.object(clock, "write_state") as write:
            with self.assertRaises(StopLoop):
                self.worker.run()
            self.assertEqual([30, 60, 120, 240, 300, 300, 300], [call.args[0] for call in sleep.call_args_list])
            self.assertTrue(all(call.args[1] == "status.json" for call in write.call_args_list))

    def clock_commands(self, step_result=None, unmanaged=False, interrupt=False):
        calls = []
        active = True

        def run(args, timeout=5):
            nonlocal active
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, 15)
            calls.append(args)
            if args[:2] == ["systemctl", "show"]:
                if args[2] == "ntpsec.service":
                    return result(f"Id=ntpsec.service\nLoadState=loaded\nActiveState={'active' if active else 'inactive'}\n")
                return result(f"Id={args[2]}\nLoadState=not-found\nActiveState=inactive\n", status=1)
            if args[:2] == ["systemctl", "stop"]:
                active = False
                return result()
            if args[:2] == ["systemctl", "start"]:
                active = True
                return result()
            if args[0] == "ps":
                return result("123\n" if unmanaged else "", status=0 if unmanaged else 1)
            if args[0] == "ntpdig":
                if "-S" in args:
                    self.assertFalse(active, "ntpd must be paused during the step")
                    if interrupt:
                        raise SystemExit(0)
                    return step_result if step_result is not None else reply(True)
                return reply(False)
            self.fail(f"unexpected command: {args}")

        return run, calls

    def test_successful_step_pauses_and_restores_the_managed_daemon(self):
        run, calls = self.clock_commands()
        with mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                mock.patch.object(clock, "command", side_effect=run), \
                mock.patch.object(clock.time, "time", return_value=NOW):
            self.assertEqual(clock.SERVERS[0], self.worker.sync_once())
        self.assertEqual(1, sum(args[:2] == ["systemctl", "stop"] for args in calls))
        self.assertEqual(["systemctl", "start", "--no-block", "ntpsec.service"], calls[-1])

    def test_failed_step_or_unmanaged_daemon_never_reports_sync(self):
        for step, unmanaged in ((result(reply(True).stdout, 1), False), (reply(True), True)):
            run, calls = self.clock_commands(step, unmanaged=unmanaged)
            with self.subTest(unmanaged=unmanaged), \
                    mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                    mock.patch.object(clock, "command", side_effect=run), \
                    mock.patch.object(clock.time, "time", return_value=NOW):
                self.assertIsNone(self.worker.sync_once())
            self.assertEqual(["systemctl", "start", "--no-block", "ntpsec.service"], calls[-1])
            if unmanaged:
                self.assertFalse(any(args[0] == "ntpdig" and "-S" in args for args in calls))

    def test_false_success_without_actual_clock_change_is_rejected(self):
        run, _ = self.clock_commands()
        with mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                mock.patch.object(clock, "command", side_effect=run), \
                mock.patch.object(clock.time, "time", return_value=NOW - 100000):
            self.assertIsNone(self.worker.sync_once())

    def test_interrupt_during_step_restores_ntpd(self):
        run, calls = self.clock_commands(interrupt=True)
        with mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                mock.patch.object(clock, "command", side_effect=run):
            with self.assertRaises(SystemExit):
                self.worker.sync_once()
        self.assertEqual(["systemctl", "start", "--no-block", "ntpsec.service"], calls[-1])

    def test_masked_inactive_time_services_do_not_block_a_step(self):
        def run(args, timeout=5):
            if args[0] == "systemctl":
                return result(f"Id={args[2]}\nLoadState=masked\nActiveState=inactive\n")
            return result("", 1)
        with mock.patch.object(clock, "command", side_effect=run):
            with self.worker.exclusive_clock():
                pass

    def test_ntp_and_chrony_aliases_are_recognized_and_restarted_once_each(self):
        calls = []

        def run(args, timeout=5):
            calls.append(args)
            if args[:2] == ["systemctl", "show"]:
                unit = {"ntp.service": "ntpsec.service",
                        "chronyd.service": "chrony.service"}.get(args[2], args[2])
                if unit == "systemd-timesyncd.service":
                    return result(f"Id={unit}\nLoadState=not-found\nActiveState=inactive\n", 1)
                return result(f"Id={unit}\nLoadState=loaded\nActiveState=active\n")
            return result("", 1 if args[0] == "ps" else 0)

        with mock.patch.object(clock, "command", side_effect=run):
            with self.worker.exclusive_clock():
                pass
        stops = [args[2] for args in calls if args[:2] == ["systemctl", "stop"]]
        starts = [args[3] for args in calls if args[:2] == ["systemctl", "start"]]
        self.assertEqual(["ntpsec.service", "chrony.service"], stops)
        self.assertEqual(stops, starts)

    def test_timeout_stopping_service_still_queues_its_restart(self):
        responses = [result("Id=ntpsec.service\nLoadState=loaded\nActiveState=active\n"),
                     None, result()]
        with mock.patch.object(clock, "command", side_effect=responses) as run:
            with self.assertRaises(OSError):
                with self.worker.exclusive_clock():
                    self.fail("step must not run after a timed-out stop")
        self.assertEqual(["systemctl", "start", "--no-block", "ntpsec.service"], run.call_args.args[0])

    def test_unmounted_mutable_is_not_used_for_persistence(self):
        with mock.patch.object(clock.os.path, "ismount", return_value=False):
            with self.assertRaises(OSError):
                clock.private_directory(clock.PERSIST_DIR)

    def test_fallback_advances_only_old_clock_and_is_not_marked_verified(self):
        saved = {"schema": 1, "epoch": NOW, "source": "ntpd"}
        with mock.patch.object(clock, "read_state", return_value=saved), \
                mock.patch.object(clock.time, "time", return_value=NOW - 10000), \
                mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                mock.patch.object(self.worker, "exclusive_clock", return_value=contextlib.nullcontext()), \
                mock.patch.object(clock, "command", return_value=result()) as run:
            self.worker.restore_fallback()
        self.assertEqual(["date", "--set", f"@{NOW}"], run.call_args.args[0])
        self.assertEqual(NOW, self.worker.fallback_epoch)
        self.assertIsNone(self.worker.last_verified)

    def test_corrupt_future_or_backward_fallback_does_not_change_clock(self):
        for saved in ({}, {"schema": 1, "epoch": float("nan"), "source": "ntpd"},
                      {"schema": 1, "epoch": NOW + 100, "source": "http"},
                      {"schema": 1, "epoch": NOW - 100, "source": "ntpd"},
                      {"schema": 1, "epoch": clock.MAX_EPOCH, "source": "ntpd"}):
            with self.subTest(saved=saved), \
                    mock.patch.object(clock, "read_state", return_value=saved), \
                    mock.patch.object(clock.time, "time", return_value=NOW), \
                    mock.patch.object(clock, "command") as run:
                self.worker.restore_fallback()
                run.assert_not_called()

    def test_persistence_failure_does_not_lose_verified_status(self):
        with mock.patch.object(clock.time, "time", return_value=NOW), \
                mock.patch.object(clock, "read_state", side_effect=FileNotFoundError), \
                mock.patch.object(clock, "write_state", side_effect=OSError("read-only")):
            self.assertTrue(self.worker.record_verified("ntpd", 1))
            self.assertEqual(clock.utc(NOW), self.worker.last_verified)

    def test_persistent_writes_are_bounded_across_retries_and_reboots(self):
        with mock.patch.object(clock.time, "time", return_value=NOW), \
                mock.patch.object(clock.time, "monotonic", return_value=1), \
                mock.patch.object(clock, "read_state", side_effect=FileNotFoundError), \
                mock.patch.object(clock, "write_state") as write:
            self.worker.record_verified("ntpd", 1)
            self.worker.record_verified("ntpd", 2)
            self.assertEqual(1, sum(call.args[1] == "last-sync.json" for call in write.call_args_list))
        self.worker = clock.ClockWorker()
        with mock.patch.object(clock.time, "time", return_value=NOW), \
                mock.patch.object(clock, "read_state", return_value={"schema": 1, "epoch": NOW - 100, "source": "ntpd"}), \
                mock.patch.object(clock, "write_state") as write:
            self.worker.record_verified("ntpd", 1)
            self.assertEqual(0, sum(call.args[1] == "last-sync.json" for call in write.call_args_list))

    def test_atomic_write_keeps_previous_record_on_replace_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            existing = directory / "last-sync.json"
            existing.write_text("previous", encoding="utf-8")
            with mock.patch.object(clock, "private_directory"), \
                    mock.patch.object(clock.os, "replace", side_effect=OSError("read-only")):
                with self.assertRaises(OSError):
                    clock.write_state(directory, "last-sync.json", {"epoch": NOW})
            self.assertEqual("previous", existing.read_text(encoding="utf-8"))
            self.assertEqual([existing], list(directory.iterdir()))

    @unittest.skipUnless(os.name == "posix", "Linux ownership and symlink checks")
    def test_state_rejects_symlink_directory_file_and_non_private_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            real = directory / "real"
            real.mkdir(mode=0o700)
            linked = directory / "linked"
            linked.symlink_to(real, target_is_directory=True)
            with self.assertRaises(OSError):
                clock.private_directory(linked)
            target = directory / "target"
            target.write_text("{}", encoding="utf-8")
            (real / "last-sync.json").symlink_to(target)
            with self.assertRaises(OSError):
                clock.read_state(real, "last-sync.json")
            real.chmod(0o777)
            with self.assertRaises(OSError):
                clock.private_directory(real)


if __name__ == "__main__":
    unittest.main()
