"""Exercise the exact embedded archive timestamp reader without shell side effects.

The descriptor boundary is mocked so these checks also run on Windows; the
archive-common shell suite additionally exercises the atomic writer on Linux.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
import types
import unittest
from unittest import mock


SOURCE = (Path(__file__).resolve().parents[1] / "run" / "archive-common.sh").read_text(encoding="utf-8")
READER = re.search(r'python3 - "\$ARCHIVE_STATUS_FILE" "\$1" "\$2" <<\'PY\'\n(.*?)\nPY', SOURCE, re.S)[1]
COMPILED = compile(READER, "archive-common.sh:timestamp-reader", "exec")
PREVIOUS = "2026-08-02T00:00:01Z"
CURRENT = "2026-08-03T00:00:01Z"


class StatusTimestampTests(unittest.TestCase):
    def read(self, previous, result="running", finished="", *, mode=stat.S_IFREG | 0o644, owner=1000, error=None, reported_size=None):
        body = previous if isinstance(previous, bytes) else json.dumps(previous).encode("utf-8")

        class Capture(io.BytesIO):
            def fileno(self):
                return 17

        source = Capture(body)
        info = types.SimpleNamespace(st_mode=mode, st_uid=owner, st_size=len(body) if reported_size is None else reported_size)
        with contextlib.ExitStack() as stack:
            nofollow = getattr(os, "O_NOFOLLOW", 0x20000)
            nonblock = getattr(os, "O_NONBLOCK", 0x800)
            stack.enter_context(mock.patch.object(os, "O_NOFOLLOW", nofollow, create=True))
            stack.enter_context(mock.patch.object(os, "O_NONBLOCK", nonblock, create=True))
            stack.enter_context(mock.patch.object(os, "geteuid", return_value=1000, create=True))
            opener = stack.enter_context(mock.patch.object(os, "open", side_effect=error, return_value=17))
            stack.enter_context(mock.patch.object(os, "fdopen", return_value=source))
            stack.enter_context(mock.patch.object(os, "fstat", return_value=info))
            stack.enter_context(mock.patch.object(sys, "argv", ["-", "/trusted/archive-status.json", result, finished]))
            output = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            exec(COMPILED, {"__name__": "__main__"})
            opener.assert_called_once_with("/trusted/archive-status.json", os.O_RDONLY | nofollow | nonblock)
            return output.getvalue().strip()

    def test_preserves_success_across_running_error_idle_and_restart(self):
        previous = {"schema_version": 1, "last_result": "error", "last_successful_at": PREVIOUS}
        for state in ("running", "error", "idle"):
            with self.subTest(state=state):
                self.assertEqual(self.read(previous, state, CURRENT), PREVIOUS)

    def test_only_success_advances_timestamp(self):
        previous = {"schema_version": 1, "last_result": "error", "last_successful_at": PREVIOUS}
        self.assertEqual(self.read(previous, "success", CURRENT), CURRENT)

    def test_migrates_legacy_success_but_never_legacy_failure(self):
        self.assertEqual(self.read({"schema_version": 1, "last_result": "success", "last_finished": PREVIOUS}), PREVIOUS)
        self.assertEqual(self.read({"schema_version": 1, "last_result": "error", "last_finished": PREVIOUS}), "")

    def test_missing_status_starts_unknown_and_success_creates_history(self):
        self.assertEqual(self.read({}, error=FileNotFoundError()), "")
        self.assertEqual(self.read({}, "success", CURRENT, error=FileNotFoundError()), CURRENT)

    def test_invalid_success_completion_keeps_previous(self):
        for timestamp in ("", "2026-02-30T00:00:00Z", "2026-01-01T25:00:00Z", "2026-08-03T00:00:01+00:00", "$(touch /tmp/file)", CURRENT + "\n"):
            with self.subTest(timestamp=timestamp):
                self.assertEqual(self.read({"schema_version": 1, "last_successful_at": PREVIOUS}, "success", timestamp), PREVIOUS)

    def test_rejects_invalid_previous_values_and_schemas(self):
        for previous in (
            {"schema_version": True, "last_successful_at": PREVIOUS},
            {"schema_version": 2, "last_successful_at": PREVIOUS},
            {"schema_version": "1", "last_successful_at": PREVIOUS},
            {"schema_version": 1, "last_successful_at": [PREVIOUS]},
            {"schema_version": 1, "last_successful_at": "2026-02-30T00:00:01Z"},
            {"schema_version": 1, "last_successful_at": "`id`"},
            [], b"invalid JSON", b"\xff",
            ('{"schema_version":1,"schema_version":1,"last_successful_at":"' + PREVIOUS + '"}').encode(),
        ):
            with self.subTest(previous=previous):
                self.assertEqual(self.read(previous), "")

    def test_rejects_untrusted_and_unbounded_files(self):
        previous = {"schema_version": 1, "last_successful_at": PREVIOUS}
        for options in ({"owner": 2000}, {"mode": stat.S_IFREG | 0o666}, {"mode": stat.S_IFIFO | 0o644}, {"mode": stat.S_IFLNK | 0o777}, {"reported_size": 16385}, {"error": PermissionError()}):
            with self.subTest(options=options):
                self.assertEqual(self.read(previous, **options), "")
        # Bound the actual read too, in case the file grows after fstat.
        self.assertEqual(self.read(b" " * 16385, reported_size=100), "")


if __name__ == "__main__":
    unittest.main()
