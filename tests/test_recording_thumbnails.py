"""Thumbnail contracts and isolated cache/encoder tests; no Pi media is used."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import urlencode


CGI = Path(__file__).resolve().parents[1] / "teslausb-www/html/cgi-bin"
SPEC = importlib.util.spec_from_file_location("thumbnail_media", CGI / "recording-media.py")
media = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(media)
EVENT = "SentryClips/2026-09-07_14-30-00"
NAME = "2026-09-07_14-29-00-front.mp4"
PATH = EVENT + "/" + NAME
INFO = SimpleNamespace(st_dev=1, st_ino=2, st_size=3, st_mtime_ns=4)


def header_fixture(width=480, height=310):
    # Structural header fixture, not an image-decoding fixture. The real ffmpeg
    # test below independently verifies an actual decodable single-frame JPEG.
    sof = b"\xff\xc0" + struct.pack(">HBHHB", 17, 8, height, width, 3) + b"\x01\x22\x00\x02\x11\x00\x03\x11\x00"
    sos = b"\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00"
    return b"\xff\xd8" + sof + sos + b"\x01\xff\xd9"


def response(output):
    head, body = output.getvalue().split(b"\r\n\r\n", 1)
    return dict(line.split(": ", 1) for line in head.decode("ascii").split("\r\n")), body


class ThumbnailContracts(unittest.TestCase):
    def test_profile_identity_is_separate_and_tracks_source_changes(self):
        low = media.fingerprint(PATH, INFO)
        thumb = media.fingerprint(PATH, INFO, media.THUMBNAIL_VERSION)
        self.assertNotEqual(low, thumb)
        for changes in ({"st_mtime_ns": 5}, {"st_ino": 9}, {"st_size": 5}):
            info = SimpleNamespace(**{**vars(INFO), **changes})
            self.assertNotEqual(thumb, media.fingerprint(PATH, info, media.THUMBNAIL_VERSION))
        self.assertNotEqual(thumb, media.fingerprint(PATH.replace("front", "back"), INFO, media.THUMBNAIL_VERSION))

    def test_still_payload_never_promises_live_or_low_video(self):
        for state in ("not_requested", "preparing", "failed", "unavailable", "ready"):
            with self.subTest(state=state):
                value = media.thumbnail_payload(PATH, {"state": state, "reason": "fixture"})
                self.assertFalse(value["live"])
                self.assertEqual(value["max_width"], 480)
                self.assertEqual(value["quality"], "thumbnail")
                self.assertNotIn("preview_url", value)
                self.assertIn("keyframe", value["description"])
                self.assertEqual(bool(value["thumbnail_url"]), state == "ready")

    def test_missing_cache_and_encoder_are_explicit(self):
        with patch.object(media, "PreviewCache", side_effect=FileNotFoundError):
            value = media.thumbnail_status(PATH, INFO)
        self.assertEqual(value["reason"], "thumbnail_storage_unavailable")
        cache = SimpleNamespace(state=lambda _key, **_kw: {"state": "not_requested", "reason": "thumbnail_not_requested"}, close=lambda: None)
        with patch.object(media, "PreviewCache", return_value=cache), patch.object(media.os, "access", return_value=False):
            value = media.thumbnail_status(PATH, INFO, request=True)
        self.assertEqual(value["reason"], "ffmpeg_not_installed")
        self.assertIsNone(value["thumbnail_url"])

    def test_get_does_not_start_encoder_and_thumbnail_needs_no_ffprobe(self):
        cache = SimpleNamespace(state=lambda _key, **_kw: {"state": "not_requested", "reason": "thumbnail_not_requested"}, close=lambda: None)
        with patch.object(media, "PreviewCache", return_value=cache), patch.object(media.os, "access", return_value=True) as access, patch.object(media.subprocess, "Popen") as launch:
            value = media.thumbnail_status(PATH, INFO)
        self.assertEqual(value["state"], "not_requested")
        access.assert_called_once_with(media.FFMPEG, os.X_OK)
        launch.assert_not_called()

    def test_jpeg_header_size_and_dimensions_are_bounded(self):
        self.assertEqual(media.thumbnail_dimensions(header_fixture()), (480, 310))
        for data in (b"", b"not-jpeg", header_fixture()[:-2], header_fixture(width=481),
                     header_fixture(height=2161), header_fixture(width=0),
                     header_fixture() + b"x" * media.MAX_THUMBNAIL_BYTES,
                     b"\xff\xd8\xff\xe0\xff\xff\xff\xd9"):
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                media.thumbnail_dimensions(data)

    def test_thumbnail_entrypoints_recheck_tombstones_before_cache(self):
        for operation in ("thumbnail-status", "thumbnail-request", "thumbnail-media"):
            output = io.BytesIO()
            reader = SimpleNamespace(open=lambda _path: (_ for _ in ()).throw(media.MediaError("404 Not Found", "hidden")))
            with patch.object(media, "SourceReader", return_value=reader), patch.object(media, "metadata_deadline", contextlib.nullcontext), patch.object(media, "PreviewCache") as cache, patch.object(media.sys, "stdout", SimpleNamespace(buffer=output)), patch.dict(os.environ, {"QUERY_STRING": urlencode({"path": PATH})}):
                media.main(operation)
            cache.assert_not_called()
            self.assertEqual(response(output)[0]["Status"], "404 Not Found")

    def test_restored_owned_copies_offer_original_without_starting_encoder(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / NAME
            source.write_bytes(b"owned-original")
            for operation in ("thumbnail-status", "thumbnail-request", "thumbnail-media"):
                output = io.BytesIO()
                descriptor = os.open(source, os.O_RDONLY)
                reader = SimpleNamespace(open=lambda _path: (descriptor, os.fstat(descriptor)),
                                         restored_paths={PATH: "/api/v1/trash/media?id=" + "a" * 64 + "&file=" + NAME})
                with patch.object(media, "SourceReader", return_value=reader), patch.object(media, "metadata_deadline", contextlib.nullcontext), patch.object(media, "PreviewCache") as cache, patch.object(media.sys, "stdout", SimpleNamespace(buffer=output)), patch.dict(os.environ, {"QUERY_STRING": urlencode({"path": PATH})}):
                    media.main(operation)
                cache.assert_not_called()
                head, body = response(output)
                if operation.endswith("-media"):
                    self.assertEqual(head["Status"], "404 Not Found")
                else:
                    value = json.loads(body)
                    self.assertEqual(value["reason"], "restored_original_only")
                    self.assertIsNone(value["thumbnail_url"])
                    self.assertTrue(value["original_url"].startswith("/api/v1/trash/media?"))


@unittest.skipUnless(os.name == "posix", "Linux private-cache, descriptor and flock security")
class ThumbnailCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.root.chmod(0o700)
        self.cache = media.PreviewCache(str(self.root))
        self.addCleanup(self.cache.close)
        self.key = media.fingerprint(PATH, INFO, media.THUMBNAIL_VERSION)

    def write(self, name, content):
        descriptor = self.cache.open_file(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
        with os.fdopen(descriptor, "wb") as target:
            target.write(content)

    def ready(self):
        data = header_fixture()
        self.write(self.key + ".jpg", data)
        self.cache.write_state(self.key, "ready", "thumbnail_ready", size_bytes=len(data), width=480, height=310)
        return data

    def test_thumbnail_and_low_share_one_worker_lock(self):
        import fcntl
        lock = self.cache.open_file("worker.lock", os.O_RDWR | os.O_CREAT)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            real = media.PreviewCache
            with patch.object(media, "PreviewCache", side_effect=lambda: real(str(self.root))), patch.object(media.os, "access", return_value=True), patch.object(media.subprocess, "Popen") as launch:
                for function in (media.preview_status, media.thumbnail_status):
                    value = function(PATH, INFO, request=True, source_fd=99)
                    self.assertEqual(value["reason"], "preview_worker_busy")
                    self.assertEqual(value["retry_after_seconds"], 5)
                launch.assert_not_called()
        finally:
            os.close(lock)

    def test_profile_reads_only_its_own_extension_and_deadline(self):
        self.write(self.key + ".mp4", b"a-low-video")
        self.cache.write_state(self.key, "ready", "thumbnail_ready")
        self.assertEqual(self.cache.state(self.key, thumbnail=True)["reason"], "thumbnail_expired")
        self.cache.write_state(self.key, "preparing", "thumbnail_preparing")
        with patch.object(media.time, "time", return_value=time.time() + 60):
            self.assertEqual(self.cache.state(self.key, thumbnail=True)["reason"], "thumbnail_timed_out")
            self.assertEqual(self.cache.state(self.key)["state"], "preparing")

    def test_jpeg_and_mp4_count_together_toward_cache_budget(self):
        jpg, mp4 = self.key + ".jpg", "b" * 64 + ".mp4"
        self.write(jpg, b"j" * 60)
        self.write(mp4, b"m" * 60)
        os.utime(self.root / jpg, (time.time() - 60, time.time() - 60))
        with patch.object(media, "MAX_CACHE_BYTES", 100):
            self.cache.prune()
        self.assertFalse((self.root / jpg).exists())
        self.assertTrue((self.root / mp4).exists())

    def test_old_jpeg_and_temporary_jpeg_are_evicted(self):
        for name in (self.key + ".jpg", "b" * 64 + ".123.jpg.tmp"):
            self.write(name, b"fixture")
            os.utime(self.root / name, (time.time() - 8 * 86400,) * 2)
        self.cache.prune()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_small_jpegs_leave_file_count_headroom_for_both_encoders(self):
        for number in range(12):
            self.write(format(number, "064x") + ".jpg", b"small")
        with patch.object(media, "MAX_CACHE_ENTRIES", 12):
            self.cache.prune(reserve=media.MAX_THUMBNAIL_BYTES)
        self.assertLessEqual(len(list(self.root.iterdir())), 8)
        # Another request can still prune normally, instead of reaching the
        # fail-closed directory-scan limit with an otherwise tiny byte count.
        self.cache.prune(reserve=media.MAX_PREVIEW_BYTES)

    def test_jpeg_symlinks_and_hardlinks_are_refused(self):
        outside = self.root / "outside"
        outside.write_bytes(header_fixture())
        outside.chmod(0o600)
        self.cache.write_state(self.key, "ready", "thumbnail_ready")
        alias = self.root / (self.key + ".jpg")
        alias.symlink_to(outside)
        with self.assertRaises(OSError):
            self.cache.state(self.key, thumbnail=True)
        alias.unlink()
        os.link(outside, alias)
        with self.assertRaises(media.MediaError):
            self.cache.state(self.key, thumbnail=True)

    def test_jpeg_response_has_exact_bytes_ranges_and_source_identity(self):
        data = self.ready()
        real = media.PreviewCache
        for requested, expected in (("", data), ("bytes=0-9", data[:10])):
            output = io.BytesIO()
            with patch.object(media, "PreviewCache", side_effect=lambda: real(str(self.root))), patch.dict(os.environ, {"HTTP_RANGE": requested}):
                media.serve_thumbnail(PATH, INFO, output)
            head, body = response(output)
            self.assertEqual(head["Content-Type"], "image/jpeg")
            self.assertEqual(int(head["Content-Length"]), len(expected))
            self.assertEqual(body, expected)
        changed = SimpleNamespace(**{**vars(INFO), "st_ino": 3})
        with patch.object(media, "PreviewCache", side_effect=lambda: real(str(self.root))), self.assertRaises(media.MediaError):
            media.serve_thumbnail(PATH, changed, io.BytesIO())

    def test_start_failure_is_reported_without_fake_ready_image(self):
        real = media.PreviewCache
        with patch.object(media, "PreviewCache", side_effect=lambda: real(str(self.root))), patch.object(media.os, "access", return_value=True), patch.object(media.subprocess, "Popen", side_effect=OSError("fixture")):
            value = media.thumbnail_status(PATH, INFO, request=True, source_fd=99)
        self.assertEqual(value["reason"], "thumbnail_start_failed")
        self.assertIsNone(value["thumbnail_url"])

    def test_timeout_or_oversized_worker_output_never_publishes_jpeg(self):
        import fcntl
        source = self.root / "source.mp4"
        source.write_bytes(b"isolated-invalid-source")
        for failure in ("timeout", "oversized"):
            with self.subTest(failure=failure):
                descriptor = os.open(source, os.O_RDONLY)
                lock = self.cache.open_file("worker.lock", os.O_RDWR | os.O_CREAT)
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                def fake_run(args, **options):
                    self.assertEqual(options["timeout"], 20)
                    self.assertIs(options["preexec_fn"], media.thumbnail_limits)
                    self.assertEqual(args[args.index("-frames:v") + 1], "1")
                    self.assertEqual(args[args.index("-skip_frame") + 1], "nokey")
                    self.assertNotIn("libx264", args)
                    if failure == "timeout":
                        raise subprocess.TimeoutExpired(args, 20)
                    os.write(options["pass_fds"][1], b"x" * media.MAX_THUMBNAIL_BYTES)
                    return SimpleNamespace(returncode=0)
                with patch.object(media.subprocess, "run", side_effect=fake_run):
                    media.thumbnail_worker(self.key, descriptor, lock, cache_root=str(self.root), require_readonly=False)
                self.assertEqual(self.cache.state(self.key, thumbnail=True)["state"], "failed")
                self.assertFalse((self.root / (self.key + ".jpg")).exists())
                self.assertFalse(list(self.root.glob("*.jpg.tmp")))


@unittest.skipUnless(os.name == "posix" and os.path.isfile(media.FFMPEG) and os.path.isfile(media.FFPROBE),
                     "Linux ffmpeg/ffprobe for real isolated JPEG encoding")
class ThumbnailEncodingTests(unittest.TestCase):
    def test_first_keyframe_is_one_decodable_bounded_jpeg_and_original_is_unchanged(self):
        import fcntl
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, cache_root = root / NAME, root / "cache"
            cache_root.mkdir(mode=0o700)
            subprocess.run([media.FFMPEG, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                            "testsrc2=size=1280x720:rate=15", "-t", "2", "-c:v", "libx264",
                            "-pix_fmt", "yuv420p", "-threads", "1", "-movflags", "+faststart", str(source)],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30, check=True)
            original = hashlib.sha256(source.read_bytes()).hexdigest()
            cache = media.PreviewCache(str(cache_root))
            try:
                descriptor = os.open(source, os.O_RDONLY)
                key = media.fingerprint(PATH, os.fstat(descriptor), media.THUMBNAIL_VERSION)
                lock = cache.open_file("worker.lock", os.O_RDWR | os.O_CREAT)
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                cache.write_state(key, "preparing", "thumbnail_preparing")
                self.assertEqual(media.thumbnail_worker(key, descriptor, lock, cache_root=str(cache_root), require_readonly=False), 0)
                value = cache.state(key, thumbnail=True)
                self.assertEqual(value["state"], "ready", value)
                jpeg = cache_root / (key + ".jpg")
                self.assertLess(jpeg.stat().st_size, media.MAX_THUMBNAIL_BYTES)
                self.assertEqual(media.thumbnail_dimensions(jpeg.read_bytes()), (480, 270))
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), original)
                result = subprocess.run([media.FFPROBE, "-v", "error", "-count_frames", "-show_entries",
                                         "stream=codec_name,width,height,nb_read_frames", "-of", "json", str(jpeg)],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=True)
                stream = json.loads(result.stdout)["streams"][0]
                self.assertEqual(stream["codec_name"], "mjpeg")
                self.assertEqual(stream["width"], 480)
                self.assertEqual(stream["nb_read_frames"], "1")
                self.assertFalse(list(cache_root.glob("*.mp4")))
            finally:
                cache.close()


if __name__ == "__main__":
    unittest.main()
