"""Exercise the Python embedded in the production video-list CGI."""

import contextlib
import errno
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
CGI = REPO_ROOT / "teslausb-www/html/cgi-bin/videolist.sh"


def load_backend():
    source = CGI.read_text(encoding="utf-8")
    marker = "<<'PYTHON'\n"
    if source.count(marker) != 1:
        raise AssertionError("Expected exactly one production Python heredoc")
    embedded = source.split(marker, 1)[1].split("\nPYTHON\n", 1)[0]
    module = types.ModuleType("video_list_backend_test")
    exec(compile(embedded, str(CGI), "exec"), module.__dict__)
    return module


backend = load_backend()


@unittest.skipUnless(os.name == "posix", "requires real Linux symlink fixtures")
class VideoLinkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="teslausb-video-list-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "index"
        self.root.mkdir()
        self.storage = self.base / "snapshot/TeslaCam"
        self.storage.mkdir(parents=True)

    def target(self, relative="RecentClips/clip.mp4"):
        target = self.storage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.touch()
        return target

    def link(self, relative, target):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
        return path

    def test_lists_relative_link_names_in_byte_order_without_reading_recordings(self):
        names = ['SavedClips/z.mp4', 'RecentClips/é "quoted" \\ clip.mp4',
                 'RecentClips/A.mp4', 'RecentClips/line\nbreak.mp4']
        for index, name in enumerate(names):
            self.link(name, self.target(f"RecentClips/{index}.mp4"))
        (self.root / "not-an-index-link.mp4").touch()
        with mock.patch("builtins.open", side_effect=AssertionError("must not open recording data")), \
                mock.patch.object(Path, "open", side_effect=AssertionError("must not open recording data")):
            self.assertEqual(sorted(names, key=os.fsencode), backend.visible_video_links(self.root))

    def test_literal_encrypted_directory_and_encrypted_targets_are_invisible(self):
        normal = self.target()
        encrypted = self.target("EncryptedClips/private.mp4")
        self.link("RecentClips/normal.mp4", normal)
        self.link("EncryptedClips/disguised.mp4", normal)
        self.link("SavedClips/direct-alias.mp4", encrypted)
        directory_alias = self.base / "ordinary-name"
        directory_alias.symlink_to(encrypted.parent, target_is_directory=True)
        self.link("SavedClips/indirect-alias.mp4", directory_alias / encrypted.name)
        self.assertEqual(["RecentClips/normal.mp4"], backend.visible_video_links(self.root))

    def test_broken_non_directory_and_cyclic_links_are_skipped(self):
        good = self.target()
        self.link("RecentClips/good.mp4", good)
        self.link("RecentClips/broken.mp4", self.base / "absent.mp4")
        self.link("RecentClips/not-directory.mp4", good / "child.mp4")
        first = self.link("RecentClips/loop-a.mp4", self.root / "RecentClips/loop-b.mp4")
        self.link("RecentClips/loop-b.mp4", first)
        self.assertEqual(["RecentClips/good.mp4"], backend.visible_video_links(self.root))

    def test_shared_target_retains_every_requested_index_path(self):
        target = self.target()
        expected = ["RecentClips/shared.mp4", "SavedClips/shared.mp4"]
        for name in expected:
            self.link(name, target)
        self.assertEqual(expected, backend.visible_video_links(self.root))

    def test_safe_parent_alias_and_relative_target_are_resolved(self):
        target = self.target()
        parent_alias = self.base / "normal-parent-alias"
        parent_alias.symlink_to(target.parent, target_is_directory=True)
        self.link("SavedClips/through-parent.mp4", parent_alias / target.name)
        relative_link = self.root / "RecentClips/relative.mp4"
        relative_link.parent.mkdir(parents=True)
        relative_link.symlink_to(os.path.relpath(target, relative_link.parent))
        self.assertEqual(["RecentClips/relative.mp4", "SavedClips/through-parent.mp4"],
                         backend.visible_video_links(self.root))

    def test_leaf_aliases_still_require_strict_encrypted_and_existence_checks(self):
        normal = self.target()
        encrypted = self.target("EncryptedClips/private.mp4")
        aliases = self.storage / "OrdinaryClips"
        aliases.mkdir()
        (aliases / "normal.mp4").symlink_to(normal)
        (aliases / "hidden.mp4").symlink_to(encrypted)
        (aliases / "broken.mp4").symlink_to(self.base / "absent")
        (aliases / "loop-a.mp4").symlink_to(aliases / "loop-b.mp4")
        (aliases / "loop-b.mp4").symlink_to(aliases / "loop-a.mp4")
        for name in ("normal.mp4", "hidden.mp4", "broken.mp4", "loop-a.mp4"):
            self.link("SavedClips/" + name, aliases / name)
        self.assertEqual(["SavedClips/normal.mp4"], backend.visible_video_links(self.root))

    def test_target_directory_scan_io_failure_is_not_ignored(self):
        target = self.target()
        self.link("RecentClips/clip.mp4", target)
        original = os.scandir

        def scan(path):
            if Path(path) == target.parent:
                raise OSError(errno.EIO, "target directory unreadable")
            return original(path)

        # The grouped implementation scans the target directory once. A
        # successful empty listing must never hide that metadata I/O error.
        with mock.patch.object(backend.os, "scandir", side_effect=scan), \
                self.assertRaises(OSError):
            backend.visible_video_links(self.root)

    def test_shared_target_parent_is_enumerated_once(self):
        names = [f"RecentClips/{number:03d}.mp4" for number in range(25)]
        for name in names:
            self.link(name, self.target(name))
        original = os.scandir
        directories = []

        def scan(path):
            directories.append(Path(path))
            return original(path)

        with mock.patch.object(backend.os, "scandir", side_effect=scan):
            self.assertEqual(names, backend.visible_video_links(self.root))
        self.assertEqual(1, directories.count(self.storage / "RecentClips"))

    def test_broken_and_looping_target_parent_aliases_are_skipped(self):
        good = self.target()
        self.link("RecentClips/good.mp4", good)
        parent_alias = self.base / "looping-parent"
        parent_alias.symlink_to(parent_alias, target_is_directory=True)
        self.link("RecentClips/parent-loop.mp4", parent_alias / "clip.mp4")
        self.link("RecentClips/missing-parent.mp4", self.base / "missing-parent/clip.mp4")
        self.assertEqual(["RecentClips/good.mp4"], backend.visible_video_links(self.root))

    def test_index_link_removed_during_scan_is_skipped(self):
        link = self.link("RecentClips/removed.mp4", self.target())
        original = os.readlink

        def readlink(path, *args, **kwargs):
            if Path(path) == link:
                raise FileNotFoundError(errno.ENOENT, "retired index link")
            return original(path, *args, **kwargs)

        with mock.patch.object(backend.os, "readlink", side_effect=readlink):
            self.assertEqual([], backend.visible_video_links(self.root))

    def test_target_retired_after_index_scan_is_skipped(self):
        target = self.target()
        self.link("RecentClips/removed.mp4", target)
        original = os.scandir

        def scan(path):
            if Path(path) == target.parent:
                raise FileNotFoundError(errno.ENOENT, "retired snapshot directory")
            return original(path)

        with mock.patch.object(backend.os, "scandir", side_effect=scan):
            self.assertEqual([], backend.visible_video_links(self.root))

    def test_directory_symlink_is_not_recursively_walked(self):
        folder = self.target().parent
        self.link("SavedClips/folder-alias", folder)
        paths = backend.visible_video_links(self.root)
        # Match the legacy link index: a directory link may be returned, but
        # must never turn into traversal of an external tree.
        self.assertEqual(["SavedClips/folder-alias"], paths)

    def test_link_resolution_permission_or_io_failure_is_not_an_empty_success(self):
        self.link("RecentClips/clip.mp4", self.target())
        for code in (errno.EACCES, errno.EIO):
            with self.subTest(errno=code), \
                    mock.patch.object(Path, "resolve", side_effect=OSError(code, "fixture failure")), \
                    self.assertRaises(OSError):
                backend.visible_video_links(self.root)

    def test_missing_index_root_fails(self):
        with self.assertRaises(FileNotFoundError):
            backend.visible_video_links(self.base / "missing-index")

    def test_child_directory_removed_during_scan_is_tolerated(self):
        child = self.root / "removed-during-cleanup"
        child.mkdir()
        original = os.scandir

        def scan(path):
            if Path(path) == child:
                raise FileNotFoundError(errno.ENOENT, "retired directory")
            return original(path)

        with mock.patch.object(backend.os, "scandir", side_effect=scan):
            self.assertEqual([], backend.visible_video_links(self.root))

    def test_directory_scan_permission_error_propagates(self):
        with mock.patch.object(backend.os, "scandir", side_effect=PermissionError(errno.EACCES, "fixture")), \
                self.assertRaises(PermissionError):
            backend.visible_video_links(self.root)

    def test_multiple_links_do_not_spawn_per_file_processes(self):
        expected = []
        for number in range(25):
            name = f"RecentClips/{number:03d}.mp4"
            self.link(name, self.target(name))
            expected.append(name)
        with contextlib.ExitStack() as patches:
            for name in ("Popen", "run", "call", "check_call", "check_output"):
                patches.enter_context(mock.patch.object(subprocess, name,
                    side_effect=AssertionError("video metadata must not spawn subprocesses")))
            for name in ("system", "popen", "posix_spawn", "posix_spawnp"):
                patches.enter_context(mock.patch.object(os, name, create=True,
                    side_effect=AssertionError("video metadata must not spawn subprocesses")))
            self.assertEqual(expected, backend.visible_video_links(self.root))


    def test_selected_day_never_reads_older_index_links_or_snapshot_targets(self):
        older = "RecentClips/2026-09-05/2026-09-05_09-00-00-front.mp4"
        selected = "SavedClips/2026-09-06_11-00-00/2026-09-06_10-59-00-front.mp4"
        old_target = self.target("older-snapshot/old.mp4")
        self.link(older, old_target)
        self.link(selected, self.target("current-snapshot/current.mp4"))
        original_scan, original_readlink = os.scandir, os.readlink
        scanned, links_read = [], []

        def scan(path):
            scanned.append(Path(path))
            return original_scan(path)

        def readlink(path, *args, **kwargs):
            links_read.append(Path(path))
            return original_readlink(path, *args, **kwargs)

        with mock.patch.object(backend.os, "scandir", side_effect=scan), \
                mock.patch.object(backend.os, "readlink", side_effect=readlink):
            response = backend.day_listing(self.root, "2026-09-06")
        self.assertEqual([selected], response["videos"])
        self.assertEqual(["2026-09-06", "2026-09-05"], response["available_days"])
        self.assertEqual("2026-09-06", response["selected_day"])
        self.assertEqual("2026-09-06_10-59-00", response["newest_recording"])
        self.assertNotIn(self.root / older, links_read)
        self.assertNotIn((self.root / older).parent, scanned)
        self.assertNotIn(old_target.parent, scanned)

    def test_latest_skips_empty_broken_encrypted_and_metadata_only_days(self):
        (self.root / "RecentClips/2026-09-07").mkdir(parents=True)
        self.link("RecentClips/2026-09-06/broken.mp4", self.base / "missing.mp4")
        self.link("SavedClips/2026-09-05_12-00-00/hidden.mp4",
                  self.target("EncryptedClips/private.mp4"))
        self.link("SentryClips/2026-09-04_12-00-00/event.json", self.target("metadata/event.json"))
        selected = "RecentClips/2026-09-03/2026-09-03_12-00-00-front.mp4"
        self.link(selected, self.target())
        response = backend.day_listing(self.root, "latest")
        self.assertEqual([selected], response["videos"])
        self.assertEqual("2026-09-03", response["selected_day"])
        self.assertEqual([f"2026-09-{day:02d}" for day in range(7, 2, -1)], response["available_days"])

    def test_latest_stops_after_newest_day_with_a_valid_recording(self):
        selected = "RecentClips/2026-09-07/newest.mp4"
        self.link(selected, self.target())
        self.link("RecentClips/2026-09-06/old.mp4", self.target("old/old.mp4"))
        original = backend.visible_video_links
        with mock.patch.object(backend, "visible_video_links", wraps=original) as scan:
            response = backend.day_listing(self.root, "latest")
        self.assertEqual([selected], response["videos"])
        self.assertEqual("2026-09-07", response["selected_day"])
        self.assertIsNone(response["newest_recording"])
        self.assertEqual(1, scan.call_count)

    def test_day_discovery_accepts_only_real_public_calendar_folders(self):
        for category, folder in (
                ("RecentClips", "2026-09-07"), ("SavedClips", "2026-09-06_23-59-59"),
                ("SentryClips", "2024-02-29_00-00-00"), ("RecentClips", "2025-02-29"),
                ("RecentClips", "2026-09-08-extra"), ("SavedClips", "2026-09-09_25-00-00"),
                ("EncryptedClips", "2026-09-10"), ("UnknownClips", "2026-09-11")):
            (self.root / category / folder).mkdir(parents=True, exist_ok=True)
        (self.root / "RecentClips/2026-09-12").symlink_to(self.storage, target_is_directory=True)
        (self.root / "RecentClips/2026-09-13").touch()
        response = backend.day_listing(self.root, "latest")
        self.assertEqual(["2026-09-07", "2026-09-06", "2024-02-29"], response["available_days"])
        self.assertEqual([], response["videos"])
        self.assertIsNone(response["selected_day"])

    def test_symlinked_public_category_is_not_discovered_or_walked(self):
        (self.storage / "2026-09-07").mkdir()
        (self.root / "RecentClips").symlink_to(self.storage, target_is_directory=True)
        response = backend.day_listing(self.root, "latest")
        self.assertEqual([], response["available_days"])
        self.assertEqual([], response["videos"])

    def test_explicit_empty_or_missing_day_is_not_replaced_by_another_day(self):
        self.link("RecentClips/2026-09-06/old.mp4", self.target())
        (self.root / "RecentClips/2026-09-07").mkdir()
        for selected in ("2026-09-07", "2026-09-08"):
            with self.subTest(day=selected):
                response = backend.day_listing(self.root, selected)
                self.assertEqual([], response["videos"])
                self.assertEqual(selected, response["selected_day"])
                self.assertIsNone(response["newest_recording"])

    def test_day_listing_retains_strict_leaf_alias_and_file_type_checks(self):
        normal = self.target()
        hidden = self.target("EncryptedClips/private.mp4")
        aliases = self.storage / "alias-targets"
        aliases.mkdir()
        (aliases / "hidden.mp4").symlink_to(hidden)
        (aliases / "normal.mp4").symlink_to(normal)
        (aliases / "directory.mp4").mkdir()
        (aliases / "directory-alias.mp4").symlink_to(normal.parent, target_is_directory=True)
        for name in ("hidden.mp4", "normal.mp4", "directory.mp4", "directory-alias.mp4"):
            self.link("RecentClips/2026-09-07/" + name, aliases / name)
        response = backend.day_listing(self.root, "2026-09-07")
        self.assertEqual(["RecentClips/2026-09-07/normal.mp4"], response["videos"])

    def test_day_discovery_io_failure_is_not_reported_as_no_recordings(self):
        with mock.patch.object(backend.os, "scandir", side_effect=OSError(errno.EIO, "unreadable")), \
                self.assertRaises(OSError):
            backend.day_listing(self.root, "latest")


class DayQueryTests(unittest.TestCase):
    def test_valid_queries_and_legacy_empty_query(self):
        for query, expected in (("", None), ("day=latest", "latest"),
                                ("day=2026-09-07", "2026-09-07"),
                                ("day=2024-02-29", "2024-02-29"),
                                ("d%61y=2026%2D09%2D07", "2026-09-07")):
            with self.subTest(query=query):
                self.assertEqual(expected, backend.parse_day_query(query))

    def test_malformed_duplicate_unknown_or_non_calendar_query_is_rejected(self):
        queries = ("day", "day=", "day=Latest", "day=2026-9-07", "day=2025-02-29",
                   "day=0000-01-01", "day=2026-09-31", "day=2026-09-07/../EncryptedClips",
                   "day=2026-09-07%00", "day=2026-09-07%0a", "day=%ff", "day=%", "day=%2",
                   "day=%zz", "day=latest&day=latest", "day=latest&x=1", "x=latest",
                   "day=latest&", "day=latest;other=1", "day=+latest", "day=é", "day=" + "1" * 129)
        for query in queries:
            with self.subTest(query=query), self.assertRaises(backend.BadQuery):
                backend.parse_day_query(query)

    def test_numeric_cache_buster_alone_or_with_day_preserves_scope(self):
        for query, expected in (("_=1788800400000", None), ("_=0", None),
                                ("_=" + "9" * 20, None), ("%5f=%31%32%33", None),
                                ("_=1788800400000&day=latest", "latest"),
                                ("day=latest&_=1788800400000", "latest"),
                                ("_=1788800400000&day=2026-09-07", "2026-09-07"),
                                ("day=2026-09-07&_=1788800400000", "2026-09-07")):
            with self.subTest(query=query):
                self.assertEqual(expected, backend.parse_day_query(query))

    def test_cache_buster_rejects_blank_non_numeric_duplicate_or_excess_parameters(self):
        queries = ("_", "_=", "_=-1", "_=+1", "_=1.0", "_=1e3", "_=123%00", "_=123%0A",
                   "_=%D9%A1", "_=" + "9" * 21, "_=1&_=2", "_=1&%5f=2", "_=1&other=2",
                   "_=1&day=", "_=1&day=2025-02-29", "_=1&day=latest&day=latest",
                   "_=1&day=latest&_=2", "_=1&day=latest&other=2", "day=latest&_=", "_=1&")
        for query in queries:
            with self.subTest(query=query), self.assertRaises(backend.BadQuery):
                backend.parse_day_query(query)

    def test_actual_legacy_random_queries_preserve_full_or_selected_scope(self):
        for random_value in ("0", "0.12345678901234567", "0." + "9" * 20,
                             "1e-7", "1.1102230246251565e-16", "9.9e-99"):
            for query, expected in ((random_value, None), ("_=" + random_value, None),
                                    ("day=latest&_=" + random_value, "latest"),
                                    ("_=" + random_value + "&day=2026-09-07", "2026-09-07")):
                with self.subTest(query=query):
                    self.assertEqual(expected, backend.parse_day_query(query))

    def test_random_cache_compatibility_does_not_accept_arbitrary_queries_or_floats(self):
        invalid_values = ("1", "0.", ".5", "00.5", "+0.5", "-0.5", "0.5 ", "0.5\n",
                          "0." + "9" * 21, "NaN", "Infinity", "1e0", "1e+3", "1e-0",
                          "10e-1", "0.1e-2", "-1e-7", "1E-7", "1e-0007", "1e-100", "1e-1000",
                          "1." + "9" * 20 + "e-7", "0.5&day=latest", "0.5&_=0.4",
                          "0.5=anything", "0.5%00", "0.5;day=latest")
        for value in invalid_values:
            with self.subTest(query=value), self.assertRaises(backend.BadQuery):
                backend.parse_day_query(value)
            # These become valid timestamp/day combinations only when named.
            if value not in ("1", "0.5&day=latest"):
                with self.subTest(query="_=" + value), self.assertRaises(backend.BadQuery):
                    backend.parse_day_query("_=" + value)
        for query in ("_=0.5&_=0.4", "_=0.5&%5f=0.4", "_=0.5&day=latest&x=1",
                      "_=0.5&day=", "_=0.5&day=2026-02-30"):
            with self.subTest(query=query), self.assertRaises(backend.BadQuery):
                backend.parse_day_query(query)

    def test_newest_recording_is_valid_filename_time_without_timezone_claim(self):
        paths = ["SavedClips/2026-09-07_12-00-00/2026-09-07_11-59-00-front.mp4",
                 "RecentClips/2026-09-07/2026-09-07_12-01-00-é camera.mp4",
                 "RecentClips/2026-09-07/2026-09-07_25-59-00-front.mp4",
                 "RecentClips/2026-09-07/2026-02-30_12-01-00-front.mp4",
                 "RecentClips/2026-09-07/2027-01-01_00-00-00-event.json"]
        self.assertEqual("2026-09-07_12-01-00", backend.newest_recording(paths))
        self.assertIsNone(backend.newest_recording(["clip.mp4", "event.json"]))

    def test_generated_at_is_explicit_utc_and_latest_empty_is_explicit(self):
        with mock.patch.object(backend, "discover_days", return_value={}):
            response = backend.day_listing("unused", "latest")
        self.assertRegex(response["generated_at"], r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
        self.assertEqual([], response["videos"])
        self.assertIsNone(response["selected_day"])
        self.assertIsNone(response["newest_recording"])

    def test_latest_fallback_shares_one_entry_budget(self):
        days = {"2026-09-07": ["RecentClips/2026-09-07"], "2026-09-06": ["RecentClips/2026-09-06"]}

        def scan(root, directories, budget, files_only):
            budget.entries += 50000
            budget.consume()
            return []

        with mock.patch.object(backend, "discover_days", return_value=days), \
                mock.patch.object(backend, "visible_video_links", side_effect=scan), \
                self.assertRaises(backend.IndexTooLarge):
            backend.day_listing("unused", "latest")


class BudgetTests(unittest.TestCase):
    def scan_entries(self, count):
        entry = types.SimpleNamespace(name="ordinary-file", is_symlink=lambda: False,
                                      is_dir=lambda follow_symlinks: False)
        entries = (entry for _ in range(count))
        with mock.patch.object(backend.os, "scandir",
                               return_value=contextlib.nullcontext(entries)):
            return backend.visible_video_links(Path("/fixture-index"))

    def test_entry_limit_accepts_boundary_and_rejects_next_entry(self):
        self.assertEqual([], self.scan_entries(100000))
        with self.assertRaises(backend.IndexTooLarge):
            self.scan_entries(100001)

    def test_expiry_handler_raises_dedicated_failure(self):
        with self.assertRaises(backend.ScanExpired):
            backend.expire_scan(14, None)


class MainResponseTests(unittest.TestCase):
    def invoke(self, mode="json", paths=None, error=None, query=""):
        output = io.StringIO()
        with mock.patch.object(backend.signal, "SIGALRM", 14, create=True), \
                mock.patch.object(backend.signal, "signal"), \
                mock.patch.object(backend.signal, "alarm", create=True) as alarm, \
                mock.patch.object(backend.sys, "argv", ["-", mode]), \
                mock.patch.dict(backend.os.environ, {"QUERY_STRING": query}), \
                mock.patch.object(backend, "scan_lock", return_value=contextlib.nullcontext()), \
                mock.patch.object(backend, "visible_video_links", return_value=paths,
                                  side_effect=error) as scan, \
                contextlib.redirect_stdout(output):
            status = backend.main()
        self.assertEqual([mock.call(20), mock.call(0)], alarm.call_args_list)
        scan.assert_called_once_with("/mutable/TeslaCam")
        return status, output.getvalue()

    def test_json_encodes_unicode_quotes_backslashes_and_newlines(self):
        paths = ['RecentClips/é "quoted" \\ clip.mp4', 'SavedClips/line\nbreak.mp4']
        status, output = self.invoke(paths=paths)
        self.assertEqual(0, status)
        self.assertEqual({"videos": paths}, json.loads(output))
        output.encode("ascii")
        self.assertEqual(1, output.count("\n"))

    def test_text_response_preserves_legacy_newline_format(self):
        self.assertEqual((0, "RecentClips/a.mp4\nSavedClips/b.mp4\n"),
                         self.invoke("text", paths=["RecentClips/a.mp4", "SavedClips/b.mp4"]))

    def test_empty_success_is_explicit_json_list(self):
        self.assertEqual((0, '{"videos":[]}\n'), self.invoke(paths=[]))

    def test_cache_buster_only_keeps_exact_legacy_json_and_text_responses(self):
        paths = ["RecentClips/2026-09-07/clip.mp4", "SavedClips/older.mp4"]
        for mode in ("json", "text"):
            for query in ("_=1788800400000", "0", "0.12345678901234567",
                          "_=0.12345678901234567", "1.1102230246251565e-16", "_=1e-7"):
                with self.subTest(mode=mode, query=query):
                    self.assertEqual(self.invoke(mode, paths=paths),
                                     self.invoke(mode, paths=paths, query=query))

    def test_scan_failures_have_nonzero_status_and_no_partial_body(self):
        for error, expected in ((backend.ScanExpired(), 75), (backend.IndexTooLarge(), 76),
                                (FileNotFoundError(errno.ENOENT, "missing root"), 74),
                                (PermissionError(errno.EACCES, "unreadable root"), 74),
                                (OSError(errno.EIO, "failed metadata read"), 74)):
            with self.subTest(error=type(error).__name__):
                self.assertEqual((expected, ""), self.invoke(error=error))

    def test_day_query_response_contains_metadata_and_uses_day_scanner(self):
        payload = {"videos": ["RecentClips/2026-09-07/clip.mp4"], "available_days": ["2026-09-07"],
                   "selected_day": "2026-09-07", "generated_at": "2026-09-07T17:00:00Z",
                   "newest_recording": None}
        for mode, query in (("json", "day=latest"), ("text", "day=latest"),
                            ("json", "day=latest&_=1788800400000"),
                            ("text", "_=1788800400000&day=latest")):
            output = io.StringIO()
            with self.subTest(mode=mode, query=query), mock.patch.object(backend.signal, "SIGALRM", 14, create=True), \
                    mock.patch.object(backend.signal, "signal"), \
                    mock.patch.object(backend.signal, "alarm", create=True), \
                    mock.patch.object(backend.sys, "argv", ["-", mode]), \
                    mock.patch.dict(backend.os.environ, {"QUERY_STRING": query}), \
                    mock.patch.object(backend, "scan_lock", return_value=contextlib.nullcontext()), \
                    mock.patch.object(backend, "day_listing", return_value=payload) as day_scan, \
                    mock.patch.object(backend, "visible_video_links") as legacy_scan, \
                    contextlib.redirect_stdout(output):
                self.assertEqual(0, backend.main())
            day_scan.assert_called_once_with("/mutable/TeslaCam", "latest")
            legacy_scan.assert_not_called()
            self.assertEqual(payload if mode == "json" else payload["videos"][0] + "\n",
                             json.loads(output.getvalue()) if mode == "json" else output.getvalue())

    def test_bad_query_and_busy_lock_fail_without_scanning_or_partial_output(self):
        for query, error, expected in (("day=../", None, 64), ("", backend.ScanBusy(), 77)):
            output = io.StringIO()
            with self.subTest(status=expected), mock.patch.object(backend.signal, "SIGALRM", 14, create=True), \
                    mock.patch.object(backend.signal, "signal"), \
                    mock.patch.object(backend.signal, "alarm", create=True), \
                    mock.patch.dict(backend.os.environ, {"QUERY_STRING": query}), \
                    mock.patch.object(backend, "scan_lock", side_effect=error) as lock, \
                    mock.patch.object(backend, "visible_video_links") as scan, \
                    contextlib.redirect_stdout(output):
                self.assertEqual(expected, backend.main())
            if expected == 64:
                lock.assert_not_called()
            scan.assert_not_called()
            self.assertEqual("", output.getvalue())


@unittest.skipUnless(os.name == "posix", "requires Linux alarms and Bash CGI")
class LinuxBoundaryTests(unittest.TestCase):
    def fixture_lock_path(self, path):
        original = os.open

        def open_lock(requested, flags, mode):
            self.assertEqual(f"/tmp/teslausb-videolist-{os.geteuid()}.lock", requested)
            self.assertEqual(0o600, mode)
            self.assertTrue(flags & os.O_NOFOLLOW)
            self.assertTrue(flags & os.O_NONBLOCK)
            self.assertTrue(flags & os.O_CLOEXEC)
            self.assertFalse(flags & os.O_TRUNC)
            return original(path, flags, mode)

        return mock.patch.object(backend.os, "open", side_effect=open_lock)

    def test_scan_lock_is_nonblocking_and_released_after_failure(self):
        with tempfile.TemporaryDirectory(prefix="teslausb-video-lock-") as temporary:
            path = Path(temporary) / "scan.lock"
            with self.fixture_lock_path(path):
                with backend.scan_lock():
                    with self.assertRaises(backend.ScanBusy):
                        with backend.scan_lock():
                            self.fail("a second scan must not acquire the lock")
                with self.assertRaises(backend.ScanExpired):
                    with backend.scan_lock():
                        raise backend.ScanExpired()
                with backend.scan_lock():
                    pass
            self.assertTrue(path.is_file())
            self.assertEqual(0o600, path.stat().st_mode & 0o777)

    def test_scan_lock_rejects_symlink_wrong_mode_nonregular_and_hardlink(self):
        with tempfile.TemporaryDirectory(prefix="teslausb-video-lock-") as temporary:
            base = Path(temporary)
            target = base / "preserve"
            target.write_text("must not modify", encoding="utf-8")
            link = base / "symlink.lock"
            link.symlink_to(target)
            wrong_mode = base / "shared.lock"
            wrong_mode.touch(mode=0o644)
            wrong_mode.chmod(0o644)
            pipe = base / "pipe.lock"
            os.mkfifo(pipe, 0o600)
            hardlink = base / "hardlink.lock"
            os.link(target, hardlink)
            target.chmod(0o600)
            for path in (link, wrong_mode, pipe, hardlink):
                with self.subTest(path=path.name), self.fixture_lock_path(path), self.assertRaises(OSError):
                    with backend.scan_lock():
                        self.fail("unsafe lock must not be acquired")
            self.assertEqual("must not modify", target.read_text(encoding="utf-8"))
            self.assertTrue(link.is_symlink())
            self.assertEqual(0o644, wrong_mode.stat().st_mode & 0o777)
            self.assertEqual(2, target.stat().st_nlink)

    def test_scan_lock_rejects_different_owner(self):
        with tempfile.TemporaryDirectory(prefix="teslausb-video-lock-") as temporary:
            path = Path(temporary) / "scan.lock"
            original = os.fstat

            def different_owner(descriptor):
                actual = original(descriptor)
                return types.SimpleNamespace(st_mode=actual.st_mode, st_uid=os.geteuid() + 1,
                                             st_nlink=actual.st_nlink)

            with self.fixture_lock_path(path), mock.patch.object(backend.os, "fstat", side_effect=different_owner), \
                    self.assertRaises(OSError):
                with backend.scan_lock():
                    self.fail("another user's lock must not be acquired")

    def test_real_alarm_ends_stalled_scan_without_success_output(self):
        driver = r'''
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("video_tests", sys.argv[1])
tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tests)
video = tests.load_backend()
import contextlib, os
os.environ["QUERY_STRING"] = ""
video.scan_lock = lambda: contextlib.nullcontext()
video.signal.alarm = lambda seconds: video.signal.setitimer(video.signal.ITIMER_REAL, 0.05 if seconds else 0)
video.visible_video_links = lambda root: time.sleep(60)
sys.argv = ["-", "json"]
sys.exit(video.main())
'''
        process = subprocess.run([sys.executable, "-B", "-c", driver, __file__],
                                 capture_output=True, text=True, timeout=5)
        self.assertEqual(75, process.returncode, process.stderr)
        self.assertEqual("", process.stdout)

    def cgi_response(self, status, mode="json", method="GET"):
        bash = shutil.which("bash", path=os.defpath)
        if bash is None:
            self.skipTest("Bash is required for the real CGI wrapper")
        driver = r'''
python3() {
  cat >/dev/null
  printf '%s\n' 'DO-NOT-LEAK-PARTIAL-SCAN'
  return "$TEST_VIDEOLIST_STATUS"
}
export -f python3
exec bash "$1"
'''
        # Do not inherit a login/SSH shell's BASH_ENV, exported functions or
        # shell options, nor real CGI request headers. TeslaUSB's root-shell
        # initialization can otherwise print status text before the CGI headers.
        # The fixture needs only standard utilities and these explicit inputs.
        environment = {"PATH": os.defpath, "LC_ALL": "C", "REQUEST_METHOD": method,
                       "TESLAUSB_API_RESPONSE": mode,
                       "TEST_VIDEOLIST_STATUS": str(status)}
        process = subprocess.run([bash, "-c", driver, "fixture", str(CGI)],
                                 env=environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(0, process.returncode, process.stderr)
        return process.stdout

    def test_real_cgi_wrapper_maps_scan_failures_to_503_without_partial_success(self):
        for status in (74, 75, 76, 77, 1, 137):
            for mode in ("json", "text"):
                with self.subTest(status=status, mode=mode):
                    response = self.cgi_response(status, mode)
                    self.assertTrue(response.startswith("Status: 503 Service Unavailable\n"))
                    self.assertNotIn("Status: 200", response)
                    self.assertNotIn("DO-NOT-LEAK", response)
                    if mode == "json":
                        body = response.split("\n\n", 1)[1]
                        self.assertIs(json.loads(body)["ok"], False)

    def test_real_cgi_wrapper_maps_invalid_query_to_400_without_partial_output(self):
        response = self.cgi_response(64)
        self.assertTrue(response.startswith("Status: 400 Bad Request\n"))
        self.assertNotIn("DO-NOT-LEAK", response)
        self.assertIs(json.loads(response.split("\n\n", 1)[1])["ok"], False)

    def test_non_get_is_rejected_before_scan(self):
        response = self.cgi_response(0, method="POST")
        self.assertTrue(response.startswith("Status: 405 Method Not Allowed\n"))
        self.assertNotIn("DO-NOT-LEAK", response)

    def test_cgi_fixture_does_not_inherit_shell_startup_or_request_environment(self):
        with tempfile.TemporaryDirectory(prefix="teslausb-video-shell-env-") as temporary:
            startup = Path(temporary) / "startup.sh"
            startup.write_text("printf 'UNEXPECTED-SHELL-STARTUP\\n'\n", encoding="utf-8")
            with mock.patch.dict(os.environ, {
                    "BASH_ENV": str(startup), "ENV": str(startup),
                    "SHELLOPTS": "errexit:nounset:xtrace", "BASHOPTS": "extdebug",
                    "HTTP_HOST": "untrusted.example", "GATEWAY_INTERFACE": "CGI/1.1",
                    "REQUEST_METHOD": "POST", "TESLAUSB_API_RESPONSE": "text"}):
                response = self.cgi_response(75)
        self.assertTrue(response.startswith("Status: 503 Service Unavailable\n"))
        self.assertNotIn("UNEXPECTED-SHELL-STARTUP", response)
        self.assertIs(json.loads(response.split("\n\n", 1)[1])["ok"], False)


if __name__ == "__main__":
    unittest.main()
