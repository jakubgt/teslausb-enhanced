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
             "adjusted": adjusted, "offset": 100.0, "ip": "192.0.2.1"}
    value.update(changes)
    return result(json.dumps(value))


class StopLoop(Exception):
    pass


class ClockTests(unittest.TestCase):
    def setUp(self):
        self.worker = clock.ClockWorker()
        self.worker.log = mock.Mock()
        sleep = mock.patch.object(clock.time, "sleep")
        self.sleep = sleep.start()
        self.addCleanup(sleep.stop)

    def test_ntp_reply_rejects_untrusted_or_invalid_success_reports(self):
        expected = (NOW, "192.0.2.1")
        self.assertEqual(expected, clock.valid_ntp_reply(reply()))
        self.assertEqual(expected, clock.valid_ntp_reply(reply(True), adjusted=True))
        self.assertEqual(expected, clock.valid_ntp_reply(reply(leap="noleap")))
        for invalid in (None, result("{}"), result("not json"), result("[]"),
                        reply(stratum=0), reply(stratum=16), reply(stratum=True),
                        reply(leap="unsync"), reply(offset=float("nan")),
                        reply(offset=True), reply(time="broken"),
                        reply(time="2026-09-04T00:00:00"),
                        reply(time="1970-01-01T00:00:00+00:00"),
                        reply(adjusted=True), result(reply().stdout, status=1)):
            with self.subTest(invalid=invalid):
                self.assertIsNone(clock.valid_ntp_reply(invalid))

    def test_step_reply_allows_only_known_clock_diagnostics_and_one_record(self):
        step = "CLOCK: time stepped by 0.014947\n"
        changed = "CLOCK: time changed from 2026-08-01 to 2026-09-04\n"
        record = reply(True).stdout + "\n"
        for output in (step + record, record + step, step + changed + record,
                       record + step + changed):
            with self.subTest(output=output):
                self.assertEqual((NOW, "192.0.2.1"),
                                 clock.valid_ntp_reply(result(output), adjusted=True))
        for output in (step + reply().stdout, "unrelated warning\n" + record,
                       "CLOCK: time stepped by nan\n" + record,
                       "CLOCK: time stepped by 0.014947 trailing\n" + record,
                       step + step + record, changed + record,
                       step + changed + changed + record,
                       step + "CLOCK: time changed from 2026-99-01 to 2026-09-04\n" + record,
                       step + record + record, step):
            with self.subTest(output=output):
                self.assertIsNone(clock.valid_ntp_reply(result(output), adjusted=True))
        self.assertIsNone(clock.valid_ntp_reply(result(step + reply().stdout)))
        self.assertIsNone(clock.valid_ntp_reply(result(step + record, 1), adjusted=True))

    def test_ntp_reply_requires_numeric_ip_and_normalizes_ipv6(self):
        self.assertEqual((NOW, "2001:db8::1"),
                         clock.valid_ntp_reply(reply(ip="2001:0db8:0:0:0:0:0:1")))
        for address in (None, True, 2130706433, "", "time.google.com",
                        "--help", "192.0.2.999", "192.0.2.1 extra", "fe80::1%eth0"):
            with self.subTest(address=address):
                self.assertIsNone(clock.valid_ntp_reply(reply(ip=address)))

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
                 ("sync_ntp, leap=10, stratum=15", True),
                 ("sync_ntp, leap=0, stratum=1", True),
                 ("sync_ntp, leap=1, stratum=2", True),
                 ("sync_ntp, leap=2, stratum=3", True),
                 ("sync_local, leap=00, stratum=2", False),
                 ("leap=00, stratum=2", False),
                 ("sync_ntp, leap=11, stratum=2", False),
                 ("sync_ntp, leap=11, stratum=16", False),
                 ("sync_ntp, leap=00, stratum=0", False),
                 ("sync_ntp, leap=00, stratum=16", False),
                 ("sync_ntp, leap=02, stratum=2", False),
                 ("sync_ntp, leap=3, stratum=2", False),
                 ("sync_ntp, leap=000, stratum=2", False),
                 ("sync_ntp, leap=10x, stratum=2", False),
                 ("", False)]
        for output, expected in cases:
            with self.subTest(output=output), mock.patch.object(clock, "command", return_value=result(output)):
                self.assertEqual(expected, self.worker.daemon_synced())

    def test_ntpd_requests_full_status_header_and_accepts_cooked_output(self):
        output = ('associd=0 status=0615 leap_none, sync_ntp, 1 event, clock_sync,\n'
                  'version="ntpd ntpsec-1.2.2", processor="aarch64",\n'
                  'leap=00, stratum=2, precision=-20, rootdelay=12.000,\n'
                  'refid=192.0.2.1, peer=12345, tc=6\n')
        with mock.patch.object(clock, "command", return_value=result(output)) as run:
            self.assertTrue(self.worker.daemon_synced())
        # Naming leap/stratum makes NTPsec suppress the status header,
        # including sync_ntp, even when the daemon is synchronized.
        run.assert_called_once_with(["ntpq", "-n", "-c", "rv 0", "127.0.0.1"])

    def test_ntpd_rejects_actual_unsynchronized_restart_status(self):
        output = ('associd=0 status=c016 leap_alarm, sync_unspec, 1 event, restart,\n'
                  'leap=11, stratum=16, refid=INIT, peer=0\n')
        with mock.patch.object(clock, "command", return_value=result(output)):
            self.assertFalse(self.worker.daemon_synced())

    def test_ntpd_failed_or_timed_out_query_is_not_verification(self):
        output = "status=0615 leap_none, sync_ntp, leap=00, stratum=2"
        for response in (None, result(output, status=1)):
            with self.subTest(response=response), \
                    mock.patch.object(clock, "command", return_value=response):
                self.assertFalse(self.worker.daemon_synced())

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

    def test_step_pins_responding_ip_and_uses_fresh_sample_after_request_gap(self):
        for address in ("192.0.2.1", "2001:db8::1"):
            events = []

            @contextlib.contextmanager
            def exclusive():
                events.append("pause")
                try:
                    yield
                finally:
                    events.append("restore")

            def run(args, timeout=5):
                events.append(args)
                self.assertEqual(15, timeout)
                if "-S" in args:
                    return result("CLOCK: time stepped by 0.014947\n"
                                  + reply(True, ip=address).stdout)
                # Other hostname addresses can time out after this response.
                return reply(ip=address, time=clock.utc(NOW - 13))

            with self.subTest(address=address), \
                    mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                    mock.patch.object(self.worker, "exclusive_clock", side_effect=exclusive), \
                    mock.patch.object(clock, "command", side_effect=run), \
                    mock.patch.object(clock.time, "time", return_value=NOW), \
                    mock.patch.object(clock.time, "sleep", side_effect=lambda seconds: events.append(seconds)):
                self.assertEqual(clock.SERVERS[0], self.worker.sync_once())
            self.assertEqual([
                ["ntpdig", "-j", "-t", "3", clock.SERVERS[0]],
                2, "pause", ["ntpdig", "-j", "-S", "-t", "3", address], "restore",
            ], events)

    def test_step_reply_from_different_ip_does_not_report_sync(self):
        run, calls = self.clock_commands(step_result=reply(True, ip="192.0.2.2"))
        with mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                mock.patch.object(clock, "command", side_effect=run), \
                mock.patch.object(clock.time, "time", return_value=NOW):
            self.assertIsNone(self.worker.sync_once())
        self.assertEqual(["systemctl", "start", "--no-block", "ntpsec.service"], calls[-1])

    def test_invalid_probe_endpoint_never_pauses_clock_daemons(self):
        with mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                mock.patch.object(clock, "command", return_value=reply(ip="not-an-ip")) as run, \
                mock.patch.object(self.worker, "exclusive_clock") as exclusive:
            self.assertIsNone(self.worker.sync_once())
        exclusive.assert_not_called()
        self.sleep.assert_not_called()
        self.assertTrue(all(call.args[0][:2] == ["ntpdig", "-j"] for call in run.call_args_list))

    def test_interrupt_during_request_gap_leaves_daemons_running(self):
        with mock.patch.object(self.worker, "daemon_synced", return_value=False), \
                mock.patch.object(clock, "command", return_value=reply()), \
                mock.patch.object(clock.time, "sleep", side_effect=SystemExit(0)), \
                mock.patch.object(self.worker, "exclusive_clock") as exclusive:
            with self.assertRaises(SystemExit):
                self.worker.sync_once()
        exclusive.assert_not_called()

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
