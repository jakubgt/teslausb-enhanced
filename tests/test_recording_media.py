"""Original byte integrity, path boundaries, range and preview contract tests."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile


CGI = Path(__file__).resolve().parents[1] / "teslausb-www/html/cgi-bin"
SPEC = importlib.util.spec_from_file_location("recording_media", CGI / "recording-media.py")
media = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(media)
EVENT = "SentryClips/2026-09-07_14-30-00"
FRONT = "2026-09-07_14-29-00-front.mp4"
BACK = "2026-09-07_14-29-00-back.mp4"


def split_response(output):
    head, body = output.getvalue().split(b"\r\n\r\n", 1)
    return dict(line.split(": ", 1) for line in head.decode("ascii").split("\r\n")), body


class ParsingTests(unittest.TestCase):
    def test_event_and_real_calendar_validation(self):
        self.assertEqual(media.event_parts(EVENT), EVENT.split("/"))
        self.assertEqual(media.event_parts("RecentClips/2026-09-07"), ["RecentClips", "2026-09-07"])
        for event in ("SavedClips/2026-02-30_00-00-00", "SentryClips/2026-09-07_24-00-00",
                      "RecentClips/2026-09-07_00-00-00", "EncryptedClips/2026-09-07",
                      "/" + EVENT, EVENT + "/..", EVENT.replace("/", "\\"), "../" + EVENT):
            with self.subTest(event=event), self.assertRaises(media.MediaError):
                media.event_parts(event)

    def test_relative_filename_validation(self):
        self.assertEqual(media.file_parts(EVENT + "/" + FRONT)[-1], FRONT)
        for name in ("../" + FRONT, "encryptedclips/" + FRONT, "event.json", FRONT + ".html",
                     FRONT.replace("front", "unknown"), FRONT.replace("2026-09-07", "2026-02-30")):
            with self.subTest(name=name), self.assertRaises(media.MediaError):
                media.file_parts(EVENT + "/" + name)

    def test_queries_reject_duplicate_unrecognized_malformed_double_encoding(self):
        valid = "path=SentryClips%2F2026-09-07_14-30-00%2F" + FRONT
        self.assertEqual(media.query_fields(valid, {"path"}, {"path"})["path"], EVENT + "/" + FRONT)
        for query in (valid + "&path=other", valid + "&root=/etc", "path=%ZZ", "path=%00",
                      "path=%FF", "path=", "", "path=x&ignored", "path=" + "a" * 2049):
            with self.subTest(query=query[:100]), self.assertRaises(media.MediaError):
                media.query_fields(query, {"path"}, {"path"})
        fields = media.query_fields("path=%252e%252e%252fetc", {"path"}, {"path"})
        with self.assertRaises(media.MediaError):
            media.file_parts(fields["path"])

    def test_snapshot_only_target_translation(self):
        for root in ("/tmp/snapshots/snap-000123", "/backingfiles/snapshots/snap-000123/mnt"):
            self.assertEqual(media.snapshot_target(root + "/TeslaCam/" + EVENT + "/" + FRONT),
                             ("snap-000123", [*EVENT.split("/"), FRONT]))
        for path in ("/mnt/cam/TeslaCam/" + EVENT + "/" + FRONT,
                     "/backingfiles/cam_disk.bin", "/tmp/snapshots/snap-000123/../etc/passwd",
                     "/tmp/snapshots/snap-000123/TeslaCam/EncryptedClips/" + FRONT,
                     "/tmp/snapshots/snap-000123/TeslaCam/enCRYPTedClips/" + FRONT,
                     "/tmp/snapshots/snap-000123/TeslaCam/SentryClips/../../" + FRONT):
            with self.subTest(path=path), self.assertRaises(media.MediaError):
                media.snapshot_target(path)

    def test_ranges_support_seek_suffix_and_clamping(self):
        for value, expected in (("", (0, 99, "200 OK")), ("bytes=0-9", (0, 9, "206 Partial Content")),
                                ("bytes=75-", (75, 99, "206 Partial Content")),
                                ("bytes=-10", (90, 99, "206 Partial Content")),
                                ("bytes=95-999", (95, 99, "206 Partial Content"))):
            self.assertEqual(media.media_range(value, 100), expected)
        for value in ("bytes=100-", "bytes=10-1", "bytes=-0", "bytes=0-2,5-8", "bytes=-", "bytes=nan-", "items=0-1"):
            with self.subTest(value=value), self.assertRaises(media.MediaError):
                media.media_range(value, 100)


class DownloadTests(unittest.TestCase):
    def selection(self, contents):
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        files = []
        for filename, data in contents:
            stream = stack.enter_context(tempfile.TemporaryFile())
            stream.write(data)
            stream.seek(0)
            files.append((EVENT + "/" + filename, stream.fileno(), os.fstat(stream.fileno())))
        result = media.Selection.__new__(media.Selection)
        result.files, result.total = files, sum(len(data) for _, data in contents)
        result.event, result.camera = EVENT, "all"
        result.download_base = "/api/v1/recordings/download?"
        result.format = "mp4" if len(contents) == 1 else "zip"
        result.filename = contents[0][0] if result.format == "mp4" else "recording.zip"
        return result

    def test_single_original_keeps_ctts_and_arbitrary_bytes_exact(self):
        data = b"\0\0\0\xffctts\x80\x01not-a-decoded-or-modified-movie"
        output = io.BytesIO()
        media.download(self.selection([(FRONT, data)]), output)
        headers, body = split_response(output)
        self.assertEqual(body, data)
        self.assertEqual(headers["Content-Type"], "video/mp4")
        self.assertEqual(int(headers["Content-Length"]), len(data))
        self.assertIn("attachment", headers["Content-Disposition"])

    def test_multi_camera_zip_is_valid_uncompressed_originals(self):
        contents = [(FRONT, b"front-ctts\x00\x80"), (BACK, b"rear-ctts\xff" * 100)]
        selection = self.selection(contents)
        output = io.BytesIO()
        media.download(selection, output)
        headers, body = split_response(output)
        self.assertNotIn("Content-Length", headers)
        self.assertEqual(int(headers["X-TeslaUSB-Source-Bytes"]), sum(len(data) for _, data in contents))
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            self.assertEqual(archive.namelist(), [name for name, _ in contents])
            for name, data in contents:
                self.assertEqual(archive.read(name), data)
                self.assertEqual(archive.getinfo(name).compress_type, zipfile.ZIP_STORED)

    def test_metadata_distinguishes_original_bytes_from_zip_size(self):
        selection = self.selection([(FRONT, b"front"), (BACK, b"back")])
        info = selection.metadata({"event": EVENT, "camera": "all", "info": "1"})
        self.assertEqual(info["size_kind"], "original_files")
        self.assertEqual(info["total_bytes"], 9)
        self.assertFalse(info["truncated"])
        self.assertNotIn("info=", info["download_url"])
        self.assertEqual([item["camera"] for item in info["files"]], ["front", "back"])

    def test_cancel_stops_further_source_reads(self):
        class Cancelled:
            def write(self, _data):
                raise BrokenPipeError()
        with patch.object(media.os, "read", return_value=b"x" * 10) as read:
            with self.assertRaises(BrokenPipeError):
                media.copy_exact(8, Cancelled(), 100)
        read.assert_called_once()

    def test_truncation_during_read_is_an_error(self):
        with patch.object(media.os, "read", side_effect=[b"ab", b""]):
            with self.assertRaises(OSError):
                media.copy_exact(8, io.BytesIO(), 100)

    def test_explicit_trash_download_uses_only_owned_files(self):
        @contextlib.contextmanager
        def locked():
            yield store
        class TrashError(Exception):
            status = 404
        with tempfile.TemporaryDirectory() as folder:
            owned = Path(folder) / FRONT
            owned.write_bytes(b"preserved-camera-bytes")
            entry = {"state": "trashed", "event": EVENT, "id": "a" * 64,
                     "files": [{"name": FRONT}]}
            store = SimpleNamespace(locked=locked, select=lambda _ids: [entry],
                                    open_owned=lambda _entry, _name: os.open(owned, os.O_RDONLY))
            module = SimpleNamespace(Store=lambda: store, TrashError=TrashError)
            with patch.object(media, "load_trash", return_value=module), patch.object(media.SourceReader, "event_directory", side_effect=AssertionError("No source fallback")):
                fields = {"id": "a" * 64, "camera": "all", "info": "1"}
                selection = media.owned_selection(fields)
                try:
                    self.assertEqual(os.read(selection.files[0][1], 100), b"preserved-camera-bytes")
                    self.assertTrue(selection.metadata(fields)["download_url"].startswith("/api/v1/trash/download?id="))
                finally:
                    selection.close()

    def test_deleted_trash_download_never_falls_back_to_source(self):
        class TrashError(Exception):
            status = 404
        @contextlib.contextmanager
        def locked():
            yield SimpleNamespace(select=lambda _ids: (_ for _ in ()).throw(TrashError("deleted")))
        module = SimpleNamespace(Store=lambda: SimpleNamespace(locked=locked), TrashError=TrashError)
        with patch.object(media, "load_trash", return_value=module), self.assertRaises(media.MediaError) as result:
            media.owned_selection({"id": "b" * 64, "camera": "all"})
        self.assertEqual(result.exception.status, "404 Not Found")


class PreviewContractTests(unittest.TestCase):
    def test_missing_storage_is_explicit_unavailable(self):
        with patch.object(media, "PreviewCache", side_effect=FileNotFoundError):
            payload = media.preview_status(EVENT + "/" + FRONT, SimpleNamespace(st_dev=1, st_ino=2, st_size=3, st_mtime_ns=4))
        self.assertEqual(payload["state"], "unavailable")
        self.assertEqual(payload["reason"], "preview_storage_unavailable")
        self.assertIsNone(payload["preview_url"])
        self.assertFalse(payload["live"])
        self.assertTrue(payload["original_url"].startswith("/TeslaCam/"))

    def test_missing_encoder_does_not_promise_low_quality(self):
        cache = SimpleNamespace(state=lambda _key: {"state": "not_requested", "reason": "preview_not_requested"}, close=lambda: None)
        with patch.object(media, "PreviewCache", return_value=cache), patch.object(media.os, "access", return_value=False):
            payload = media.preview_status(EVENT + "/" + FRONT, SimpleNamespace(st_dev=1, st_ino=2, st_size=3, st_mtime_ns=4), request=True)
        self.assertEqual(payload["state"], "unavailable")
        self.assertEqual(payload["reason"], "ffmpeg_not_installed")
        self.assertIsNone(payload["preview_url"])

    def test_ready_url_is_bound_to_current_source_identity(self):
        path = EVENT + "/" + FRONT
        first = SimpleNamespace(st_dev=1, st_ino=2, st_size=3, st_mtime_ns=4)
        second = SimpleNamespace(st_dev=1, st_ino=2, st_size=3, st_mtime_ns=5)
        self.assertNotEqual(media.fingerprint(path, first), media.fingerprint(path, second))
        self.assertNotEqual(media.fingerprint(path, first), media.fingerprint(EVENT + "/" + BACK, first))
        payload = media.preview_payload(path, {"state": "ready", "reason": "preview_ready"})
        self.assertTrue(payload["preview_url"].startswith("/api/v1/recordings/preview/media?path="))

    def test_wrapper_applies_mutation_origin_gate(self):
        wrapper = (CGI / "recording-media.sh").read_text(encoding="utf-8")
        self.assertIn("source \"$script_dir/cgi-common.sh\"", wrapper)
        self.assertIn("cgi_reject_cross_site", wrapper)
        self.assertIn("cgi_require_mutation", wrapper)
        self.assertIn("exec /usr/bin/python3 -I", wrapper)
        self.assertNotIn("eval ", wrapper)


@unittest.skipUnless(os.name == "posix", "Linux openat/O_NOFOLLOW/read-only filesystem security tests")
class SourceSecurityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.index = self.base / "index"
        self.snapshots = self.base / "snapshots"
        self.event = self.index / EVENT
        self.event.mkdir(parents=True)
        self.target = self.snapshots / "snap-000123/TeslaCam" / EVENT
        self.target.mkdir(parents=True)
        (self.target / FRONT).write_bytes(b"original-ctts")
        (self.target / BACK).write_bytes(b"other-camera")
        for name in (FRONT, BACK):
            (self.event / name).symlink_to("/backingfiles/snapshots/snap-000123/mnt/TeslaCam/" + EVENT + "/" + name)
        self.reader = media.SourceReader(str(self.index), str(self.snapshots), require_readonly=False, trash_factory=False)

    def test_exact_snapshot_alias_reads_original(self):
        descriptor, _ = self.reader.open(EVENT + "/" + FRONT)
        try:
            self.assertEqual(os.read(descriptor, 100), b"original-ctts")
        finally:
            os.close(descriptor)

    def test_all_and_one_camera_selection(self):
        self.assertEqual(self.reader.select(EVENT, "front"), [EVENT + "/" + FRONT])
        self.assertEqual(len(self.reader.select(EVENT, "all", FRONT.split("-front")[0])), 2)
        with self.assertRaises(media.MediaError):
            self.reader.select(EVENT, "all", "2026-09-07_01-00-00")

    def test_writable_snapshot_is_refused(self):
        self.reader.require_readonly = True
        with self.assertRaises(media.MediaError):
            self.reader.open(EVENT + "/" + FRONT)

    def test_final_snapshot_symlink_cannot_escape_or_alias_encrypted(self):
        (self.target / FRONT).unlink()
        encrypted = self.base / "EncryptedClips"
        encrypted.mkdir()
        (encrypted / FRONT).write_bytes(b"must-never-be-read")
        (self.target / FRONT).symlink_to(encrypted / FRONT)
        with self.assertRaises(OSError):
            self.reader.open(EVENT + "/" + FRONT)

    def test_intermediate_snapshot_symlink_cannot_escape(self):
        actual = self.snapshots / "snap-000123"
        moved = self.base / "outside"
        actual.rename(moved)
        actual.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(OSError):
            self.reader.open(EVENT + "/" + FRONT)

    def test_intermediate_index_symlink_cannot_escape(self):
        actual = self.index / "SentryClips"
        moved = self.base / "outside-index"
        actual.rename(moved)
        actual.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(OSError):
            self.reader.open(EVENT + "/" + FRONT)

    def test_link_to_live_camera_is_rejected_before_open(self):
        (self.event / FRONT).unlink()
        (self.event / FRONT).symlink_to("/mnt/cam/TeslaCam/" + EVENT + "/" + FRONT)
        with self.assertRaises(media.MediaError):
            self.reader.open(EVENT + "/" + FRONT)

    def test_sentry_alias_cannot_relabel_another_event(self):
        (self.event / FRONT).unlink()
        (self.event / FRONT).symlink_to("/tmp/snapshots/snap-000123/TeslaCam/SavedClips/2026-09-07_14-30-00/" + FRONT)
        with self.assertRaises(media.MediaError):
            self.reader.open(EVENT + "/" + FRONT)

    def test_tombstones_block_original_and_source_preview_access(self):
        @contextlib.contextmanager
        def locked():
            yield
        for state in ("trashed", "deleted"):
            store = SimpleNamespace(locked=locked, get_event=lambda _event: {"state": state}, hidden_media=lambda: set())
            self.reader.trash_factory = lambda: store
            with self.subTest(state=state), self.assertRaises(media.MediaError):
                self.reader.open(EVENT + "/" + FRONT)

    def test_restored_owned_source_supersedes_old_snapshot(self):
        @contextlib.contextmanager
        def locked():
            yield
        owned = self.base / "owned.mp4"
        owned.write_bytes(b"restored-original")
        entry = {"state": "restored", "id": "a" * 64, "files": [{"name": FRONT}]}
        store = SimpleNamespace(locked=locked, get_event=lambda _event: entry,
                                hidden_media=lambda: {FRONT},
                                open_owned=lambda _entry, _name: os.open(owned, os.O_RDONLY))
        self.reader.trash_factory = lambda: store
        self.assertEqual(self.reader.select(EVENT, "all"), [EVENT + "/" + FRONT])
        descriptor, _ = self.reader.open(EVENT + "/" + FRONT)
        try:
            self.assertEqual(os.read(descriptor, 100), b"restored-original")
            self.assertIn("/api/v1/trash/media?id=", self.reader.restored_paths[EVENT + "/" + FRONT])
        finally:
            os.close(descriptor)

    def test_unreadable_trash_state_fails_closed(self):
        self.reader.trash_factory = lambda: (_ for _ in ()).throw(OSError("unavailable"))
        with self.assertRaises(media.MediaError) as result:
            self.reader.open(EVENT + "/" + FRONT)
        self.assertEqual(result.exception.status, "503 Service Unavailable")

    def test_recent_alias_of_tombstoned_recording_is_rejected(self):
        @contextlib.contextmanager
        def locked():
            yield
        def no_event_lookup(_event):
            raise AssertionError("Recent folders are not Trash events")
        store = SimpleNamespace(locked=locked, get_event=no_event_lookup, hidden_media=lambda: {FRONT})
        self.reader.trash_factory = lambda: store
        # Rejection occurs before the alias is even opened, including cases
        # where the original event was restored as an owned copy.
        with self.assertRaises(media.MediaError) as result:
            self.reader.open("RecentClips/2026-09-07/" + FRONT)
        self.assertEqual(result.exception.status, "404 Not Found")

    def test_download_selection_omits_hidden_camera_aliases(self):
        @contextlib.contextmanager
        def locked():
            yield
        store = SimpleNamespace(locked=locked, get_event=lambda _event: None, hidden_media=lambda: {FRONT})
        self.reader.trash_factory = lambda: store
        self.assertEqual(self.reader.select(EVENT, "all"), [EVENT + "/" + BACK])


@unittest.skipUnless(os.name == "posix", "Linux private-cache and flock security tests")
class CacheSecurityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        os.chmod(self.root, 0o700)
        self.cache = media.PreviewCache(str(self.root))
        self.addCleanup(self.cache.close)
        self.key = "a" * 64

    def test_nonprivate_cache_is_refused(self):
        os.chmod(self.root, 0o755)
        with self.assertRaises(media.MediaError):
            media.PreviewCache(str(self.root))

    def test_cache_symlink_is_never_read(self):
        (self.root / (self.key + ".json")).symlink_to("/etc/passwd")
        with self.assertRaises(OSError):
            self.cache.state(self.key)

    def test_old_preparing_job_becomes_failed(self):
        self.cache.write_state(self.key, "preparing", "preview_preparing")
        with patch.object(media.time, "time", return_value=media.time.time() + media.JOB_TIMEOUT + 60):
            state = self.cache.state(self.key)
        self.assertEqual(state["state"], "failed")
        self.assertEqual(state["reason"], "preview_timed_out")

    def test_ready_without_media_expires(self):
        self.cache.write_state(self.key, "ready", "preview_ready")
        self.assertEqual(self.cache.state(self.key)["reason"], "preview_expired")

    def test_busy_worker_does_not_enqueue(self):
        import fcntl
        lock = self.cache.open_file("worker.lock", os.O_RDWR | os.O_CREAT)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            real_cache = media.PreviewCache
            with patch.object(media, "PreviewCache", side_effect=lambda: real_cache(str(self.root))), patch.object(media.os, "access", return_value=True), patch.object(media.subprocess, "Popen") as launch:
                info = SimpleNamespace(st_dev=1, st_ino=2, st_size=3, st_mtime_ns=4)
                state = media.preview_status(EVENT + "/" + FRONT, info, request=True, source_fd=9)
                launch.assert_not_called()
                self.assertEqual(state["reason"], "preview_worker_busy")
                self.assertIsNone(state["preview_url"])
        finally:
            os.close(lock)


@unittest.skipUnless(os.name == "posix" and os.path.isfile(media.FFMPEG) and os.path.isfile(media.FFPROBE),
                     "Linux ffmpeg and ffprobe are required for actual preview encoding")
class EncodingIntegrationTests(unittest.TestCase):
    def test_worker_creates_complete_smaller_browser_compatible_preview(self):
        import fcntl
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / FRONT
            cache_root = root / "cache"
            cache_root.mkdir(mode=0o700)
            result = subprocess.run(
                [media.FFMPEG, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                 "testsrc2=size=1280x720:rate=30", "-t", "2", "-c:v", "libx264",
                 "-pix_fmt", "yuv420p", "-crf", "18", "-threads", "1",
                 "-movflags", "+faststart", str(source)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                timeout=30, check=False)
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
            original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            source_fd = os.open(source, os.O_RDONLY)
            cache = media.PreviewCache(str(cache_root))
            key = media.fingerprint(EVENT + "/" + FRONT, os.fstat(source_fd))
            lock = cache.open_file("worker.lock", os.O_RDWR | os.O_CREAT)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                cache.write_state(key, "preparing", "preview_preparing")
                # Fixture files live on the test runner's writable temporary
                # filesystem. Production's worker CLI always requires ST_RDONLY.
                code = media.preview_worker(key, source_fd, lock,
                                            cache_root=str(cache_root), require_readonly=False)
                self.assertEqual(code, 0)
                state = cache.state(key)
                self.assertEqual(state["state"], "ready", state)
                output = cache_root / (key + ".mp4")
                self.assertLess(output.stat().st_size, source.stat().st_size)
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), original_hash)
                probe = subprocess.run(
                    [media.FFPROBE, "-v", "error", "-show_entries",
                     "stream=codec_name,width,height,pix_fmt,avg_frame_rate:format=duration", "-of", "json", str(output)],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    timeout=10, check=True)
                info = json.loads(probe.stdout)
                stream = info["streams"][0]
                self.assertEqual(stream["codec_name"], "h264")
                self.assertEqual(stream["pix_fmt"], "yuv420p")
                self.assertLessEqual(stream["width"], 640)
                self.assertEqual(stream["avg_frame_rate"], "12/1")
                self.assertAlmostEqual(float(info["format"]["duration"]), 2, delta=.25)
            finally:
                # The worker owns/closes passed descriptors, even on failure.
                for descriptor in (source_fd, lock):
                    with contextlib.suppress(OSError):
                        os.close(descriptor)
                cache.close()


if __name__ == "__main__":
    unittest.main()
