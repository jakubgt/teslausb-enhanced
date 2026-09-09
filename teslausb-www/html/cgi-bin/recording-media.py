"""Unprivileged immutable recording downloads and optional bounded Low previews.

The CGI wrapper owns host/origin/method validation. Paths, commands, storage
roots and resource budgets here are never configurable through request data.
Original downloads deliberately bypass the browser FUSE ctts adjustment, but
only after validating and pinning an immutable snapshot's real file.
"""

import contextlib
from datetime import datetime
import hashlib
import importlib.util
import json
import math
import os
import re
import signal
import stat
import subprocess
import sys
import time
from urllib.parse import parse_qsl, urlencode, quote
import zipfile


INDEX_ROOT = "/mutable/TeslaCam"
SNAPSHOT_ROOT = "/tmp/snapshots"
CACHE_ROOT = "/backingfiles/teslausb-previews"
FFMPEG = "/usr/bin/ffmpeg"
FFPROBE = "/usr/bin/ffprobe"
CAMERAS = frozenset(("front", "back", "left_repeater", "right_repeater",
                     "left_pillar", "right_pillar"))
CATEGORIES = frozenset(("RecentClips", "SavedClips", "SentryClips"))
STAMP = r"[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}"
FILE_PATTERN = re.compile(rf"({STAMP})-({'|'.join(sorted(CAMERAS))})\.mp4")
MAX_FILES = 512
MAX_ENTRIES = 20000
MAX_SOURCE_BYTES = 512 * 1024 * 1024
MAX_DOWNLOAD_BYTES = 16 * 1024 * 1024 * 1024
MAX_PREVIEW_BYTES = 32 * 1024 * 1024
MAX_CACHE_BYTES = 256 * 1024 * 1024
MAX_PREVIEW_SECONDS = 65
JOB_TIMEOUT = 180
CHUNK_BYTES = 256 * 1024
PREVIEW_VERSION = "h264-640-12-v1"


class MediaError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def bad_path():
    return MediaError("400 Bad Request", "Select a standard recording path.")


def valid_stamp(value, date_only=False):
    pattern = r"[0-9]{4}-[0-9]{2}-[0-9]{2}" if date_only else STAMP
    if not re.fullmatch(pattern, value):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%d" if date_only else "%Y-%m-%d_%H-%M-%S")
        return True
    except ValueError:
        return False


def event_parts(value):
    parts = value.split("/")
    if (len(parts) != 2 or parts[0] not in CATEGORIES or
            not valid_stamp(parts[1], date_only=(parts[0] == "RecentClips"))):
        raise bad_path()
    return parts


def file_parts(value):
    parts = value.split("/")
    if len(parts) != 3:
        raise bad_path()
    event_parts("/".join(parts[:2]))
    match = FILE_PATTERN.fullmatch(parts[-1])
    if not match or not valid_stamp(match[1]):
        raise bad_path()
    return parts


def query_fields(query, allowed, required):
    if (len(query) > 2048 or not query.isascii() or
            re.search(r"%(?![0-9a-fA-F]{2})", query)):
        raise bad_path()
    try:
        fields = parse_qsl(query, keep_blank_values=True, strict_parsing=True,
                           encoding="utf-8", errors="strict", max_num_fields=5)
        result = {}
        for key, value in fields:
            if (key not in allowed or key in result or not value or
                    not value.isascii() or any(ord(c) < 32 or ord(c) == 127 for c in value)):
                raise bad_path()
            result[key] = value
        if not required <= result.keys():
            raise bad_path()
        return result
    except (ValueError, UnicodeError):
        raise bad_path() from None


def open_directory(path):
    """Pin every directory component; a final O_NOFOLLOW alone is insufficient."""
    if not path.startswith("/") or any(p in (".", "..") for p in path.split("/")):
        raise bad_path()
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in path.split("/")[1:]:
            if not component:
                continue
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                              dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_fd
        result = descriptor
        descriptor = None
        return result
    finally:
        if descriptor is not None:
            os.close(descriptor)


def private_file(info, uid):
    return (stat.S_ISREG(info.st_mode) and info.st_uid == uid and
            stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1)


def snapshot_target(target):
    """Only standard immutable snapshot spellings; reject aliases before reads."""
    if any(p.lower() == "encryptedclips" for p in target.split("/")):
        raise MediaError("403 Forbidden", "Encrypted recordings are excluded.")
    match = re.fullmatch(r"/(?:tmp/snapshots/(snap-[0-9]{6})|backingfiles/snapshots/(snap-[0-9]{6})/mnt)/TeslaCam/(.+)", target)
    if not match:
        raise MediaError("403 Forbidden", "The recording is outside the snapshot view.")
    tail = match[3].split("/")
    if (tail[0] not in CATEGORIES or len(tail) not in (2, 3) or
            (len(tail) == 2 and tail[0] != "RecentClips")):
        raise bad_path()
    if len(tail) == 3 and not valid_stamp(tail[1]):
        raise bad_path()
    filename = FILE_PATTERN.fullmatch(tail[-1])
    if not filename or not valid_stamp(filename[1]):
        raise bad_path()
    return match[1] or match[2], tail


def load_trash():
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "recording-trash.py")
    spec = importlib.util.spec_from_file_location("recording_media_trash", helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SourceReader:
    # Test fixtures may override roots/read-only policy explicitly. main never
    # accepts these arguments or obtains them from the CGI environment.
    def __init__(self, index=INDEX_ROOT, snapshots=SNAPSHOT_ROOT,
                 require_readonly=True, trash_factory=None):
        self.index = index
        self.snapshots = snapshots
        self.require_readonly = require_readonly
        self.trash_factory = trash_factory
        self.restored_paths = {}
        self.active_state = None
        self.hidden_names = set()

    @contextlib.contextmanager
    def selection_scope(self, event):
        # One manifest read and one lock for the entire pinned selection.
        with self.event_state(event) as state:
            self.active_state = (event, state)
            try:
                yield
            finally:
                self.active_state = None

    @contextlib.contextmanager
    def event_state(self, event):
        if self.active_state and self.active_state[0] == event:
            yield self.active_state[1]
            return
        if self.trash_factory is False:
            self.hidden_names = set()
            yield None, None
            return
        try:
            factory = self.trash_factory
            if factory is None:
                factory = load_trash().Store
                self.trash_factory = factory
            store = factory()
            with store.locked():
                self.hidden_names = store.hidden_media()
                entry = None if event.startswith("RecentClips/") else store.get_event(event)
                if entry and entry["state"] != "restored":
                    raise MediaError("404 Not Found", "This recording is in Trash or was deleted.")
                yield store, entry
        except MediaError:
            raise
        except Exception as error:
            # Missing/corrupt/unreadable tombstones must never reveal a clip.
            raise MediaError("503 Service Unavailable", "Recording Trash state is unavailable. Retry after the current operation.") from error

    def event_directory(self, event):
        event_parts(event)
        return open_directory(self.index + "/" + event)

    def open(self, path):
        parts = file_parts(path)
        with self.event_state("/".join(parts[:2])) as (store, entry):
            if entry:
                descriptor = store.open_owned(entry, parts[-1])
                info = os.fstat(descriptor)
                if not 0 < info.st_size <= MAX_SOURCE_BYTES:
                    os.close(descriptor)
                    raise MediaError("413 Content Too Large", "The restored recording segment exceeds the supported size.")
                self.restored_paths[path] = "/api/v1/trash/media?" + urlencode({"id": entry["id"], "file": parts[-1]})
                return descriptor, info
            if parts[-1] in self.hidden_names:
                raise MediaError("404 Not Found", "This recording alias is hidden by Trash.")
        directory = self.event_directory("/".join(parts[:2]))
        try:
            # Index entries are aliases published by the snapshot workflow.
            # Readlink is metadata-only and is pinned to the approved event.
            target = os.readlink(parts[-1], dir_fd=directory)
        finally:
            os.close(directory)
        snapshot, tail = snapshot_target(target)
        if tail[-1] != parts[-1] or (parts[0] != "RecentClips" and tail != parts):
            raise MediaError("403 Forbidden", "The recording alias is invalid.")
        directory = open_directory(self.snapshots + "/" + snapshot + "/TeslaCam/" + "/".join(tail[:-1]))
        descriptor = None
        try:
            if self.require_readonly and not (os.fstatvfs(directory).f_flag & os.ST_RDONLY):
                raise MediaError("403 Forbidden", "The recording snapshot is not read-only.")
            # Pin the inode through O_NOFOLLOW. Even a concurrent alias change
            # can never redirect this open to an arbitrary or live file.
            descriptor = os.open(tail[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=directory)
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise MediaError("403 Forbidden", "The recording is not a regular file.")
            if not 0 < info.st_size <= MAX_SOURCE_BYTES:
                raise MediaError("413 Content Too Large", "The recording segment exceeds the supported size.")
            result = descriptor
            descriptor = None
            return result, info
        finally:
            if descriptor is not None:
                os.close(descriptor)
            os.close(directory)

    def select(self, event, camera, segment=None):
        event_parts(event)
        if camera != "all" and camera not in CAMERAS:
            raise bad_path()
        if segment is not None and not valid_stamp(segment):
            raise bad_path()
        with self.event_state(event) as (_, entry):
            if entry:
                names = [item["name"] for item in entry["files"]
                         if FILE_PATTERN.fullmatch(item["name"]) and
                         (camera == "all" or FILE_PATTERN.fullmatch(item["name"])[2] == camera) and
                         (segment is None or FILE_PATTERN.fullmatch(item["name"])[1] == segment)]
                if not names:
                    raise MediaError("404 Not Found", "No matching restored recordings are available.")
                if len(names) > MAX_FILES:
                    raise MediaError("413 Content Too Large", "Choose one camera or a shorter clip.")
                return [event + "/" + name for name in sorted(names)]
        directory = self.event_directory(event)
        names = []
        try:
            with os.scandir(directory) as entries:
                for count, entry in enumerate(entries):
                    if count >= MAX_ENTRIES:
                        raise MediaError("413 Content Too Large", "Choose a smaller recording event.")
                    match = FILE_PATTERN.fullmatch(entry.name)
                    if (entry.name not in self.hidden_names and match and valid_stamp(match[1]) and
                            (camera == "all" or camera == match[2]) and
                            (segment is None or segment == match[1])):
                        names.append(entry.name)
                        if len(names) > MAX_FILES:
                            raise MediaError("413 Content Too Large", "Choose one camera or a shorter clip.")
        finally:
            os.close(directory)
        if not names:
            raise MediaError("404 Not Found", "No matching recordings are available.")
        return [event + "/" + name for name in sorted(names)]


class Selection:
    def __init__(self, reader, fields):
        self.files = []
        self.total = 0
        self.event = fields["event"]
        self.camera = fields["camera"]
        self.download_base = "/api/v1/recordings/download?"
        try:
            with reader.selection_scope(self.event):
                for path in reader.select(self.event, self.camera, fields.get("segment")):
                    fd, info = reader.open(path)
                    self.files.append((path, fd, info))
                    self.total += info.st_size
                    if self.total > MAX_DOWNLOAD_BYTES:
                        raise MediaError("413 Content Too Large", "Choose one camera or a shorter clip.")
        except BaseException:
            self.close()
            raise
        self.format = "mp4" if len(self.files) == 1 else "zip"
        self.filename = (self.files[0][0].split("/")[-1] if self.format == "mp4" else
                         self.event.replace("/", "-") + "-" + self.camera + ".zip")

    def close(self):
        for _, descriptor, _ in self.files:
            os.close(descriptor)
        self.files = []

    def metadata(self, fields):
        return {"ok": True, "format": self.format, "filename": self.filename,
                "total_bytes": self.total, "size_kind": "original_files",
                "file_count": len(self.files), "truncated": False,
                "files": [{"path": path, "name": path.split("/")[-1],
                           "size_bytes": info.st_size,
                           "camera": FILE_PATTERN.fullmatch(path.split("/")[-1])[2]}
                          for path, _, info in self.files],
                "download_url": self.download_base +
                                urlencode({k: v for k, v in fields.items() if k != "info"})}


def owned_selection(fields):
    if not re.fullmatch(r"[0-9a-f]{64}", fields["id"]):
        raise bad_path()
    module = load_trash()
    try:
        with module.Store().locked() as store:
            entry = store.select([fields["id"]])[0]
            # Only this explicit Trash route permits preserved trashed content.
            # Never fall through to snapshot aliases for an absent/deleted copy.
            reader = SourceReader(trash_factory=False)
            reader.active_state = (entry["event"], (store, entry))
            selection = Selection(reader, {"event": entry["event"], "camera": fields["camera"]})
            selection.download_base = "/api/v1/trash/download?"
            return selection
    except module.TrashError as error:
        raise MediaError("404 Not Found" if error.status == 404 else "503 Service Unavailable", str(error)) from error


def headers(status, content_type, extra=None, output=None):
    output = output or sys.stdout.buffer
    values = {"Status": status, "Content-Type": content_type,
              "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
              "Referrer-Policy": "same-origin", "Cross-Origin-Resource-Policy": "same-origin",
              "X-TeslaUSB-API-Version": "1", "X-Accel-Buffering": "no"}
    values.update(extra or {})
    output.write(("\r\n".join(f"{k}: {v}" for k, v in values.items()) + "\r\n\r\n").encode("ascii"))


def json_response(value, status="200 OK", output=None):
    output = output or sys.stdout.buffer
    body = json.dumps(value, separators=(",", ":")).encode("utf-8")
    headers(status, "application/json; charset=utf-8", {"Content-Length": len(body)}, output)
    output.write(body)


def copy_exact(descriptor, output, length):
    while length:
        chunk = os.read(descriptor, min(CHUNK_BYTES, length))
        if not chunk:
            raise OSError("A snapshot disappeared during transfer")
        output.write(chunk)
        length -= len(chunk)


class StreamWriter:
    """Force ZIP data descriptors even for seekable test output."""
    def __init__(self, output):
        self.output = output
        self.position = 0

    def write(self, data):
        self.output.write(data)
        self.position += len(data)
        return len(data)

    def tell(self):
        return self.position

    def flush(self):
        self.output.flush()


def download(selection, output=None):
    output = output or sys.stdout.buffer
    extra = {"Content-Disposition": f'attachment; filename="{selection.filename}"',
             "X-TeslaUSB-Source-Bytes": selection.total,
             "X-TeslaUSB-File-Count": len(selection.files)}
    if selection.format == "mp4":
        extra["Content-Length"] = selection.total
        headers("200 OK", "video/mp4", extra, output)
        copy_exact(selection.files[0][1], output, selection.total)
    else:
        headers("200 OK", "application/zip", extra, output)
        with zipfile.ZipFile(StreamWriter(output), "w", compression=zipfile.ZIP_STORED,
                             allowZip64=True) as archive:
            for path, descriptor, info in selection.files:
                item = zipfile.ZipInfo(path.split("/")[-1])
                item.file_size = info.st_size
                item.external_attr = 0o100600 << 16
                with archive.open(item, "w", force_zip64=True) as member:
                    copy_exact(descriptor, member, info.st_size)
    output.flush()


def fingerprint(path, info):
    fields = (PREVIEW_VERSION, path, info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
    return hashlib.sha256(json.dumps(fields).encode("utf-8")).hexdigest()


class PreviewCache:
    def __init__(self, root=CACHE_ROOT):
        self.root = root
        self.fd = open_directory(root)
        info = os.fstat(self.fd)
        if (info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700):
            os.close(self.fd)
            raise MediaError("503 Service Unavailable", "Preview storage is unavailable.")

    def close(self):
        os.close(self.fd)

    def open_file(self, name, flags=os.O_RDONLY):
        descriptor = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=self.fd)
        if not private_file(os.fstat(descriptor), os.geteuid()):
            os.close(descriptor)
            raise MediaError("503 Service Unavailable", "Preview storage is unavailable.")
        return descriptor

    def state(self, key):
        try:
            descriptor = self.open_file(key + ".json")
        except FileNotFoundError:
            return {"state": "not_requested", "reason": "preview_not_requested"}
        try:
            value = json.loads(os.read(descriptor, 4097))
        except (ValueError, UnicodeError):
            return {"state": "failed", "reason": "invalid_preview_state"}
        finally:
            os.close(descriptor)
        if (not isinstance(value, dict) or value.get("state") not in ("preparing", "ready", "failed") or
                not isinstance(value.get("updated_at"), (int, float))):
            return {"state": "failed", "reason": "invalid_preview_state"}
        if value["state"] == "preparing" and time.time() - value["updated_at"] > JOB_TIMEOUT + 30:
            return {"state": "failed", "reason": "preview_timed_out"}
        if value["state"] == "ready":
            try:
                descriptor = self.open_file(key + ".mp4")
                info = os.fstat(descriptor)
                os.close(descriptor)
                if not 0 < info.st_size < MAX_PREVIEW_BYTES:
                    raise FileNotFoundError()
            except FileNotFoundError:
                return {"state": "not_requested", "reason": "preview_expired"}
        # Publish only known metadata, never arbitrary cache fields or paths.
        return {k: value[k] for k in ("state", "reason", "updated_at", "size_bytes", "duration_seconds") if k in value}

    def write_state(self, key, state, reason, **metadata):
        name = key + f".{os.getpid()}.json.tmp"
        descriptor = self.open_file(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
        try:
            payload = json.dumps({"state": state, "reason": reason,
                                  "updated_at": time.time(), **metadata}).encode("utf-8")
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload)
                stream.flush()
            os.replace(name, key + ".json", src_dir_fd=self.fd, dst_dir_fd=self.fd)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(name, dir_fd=self.fd)

    def prune(self, reserve=0):
        entries = []
        total = 0
        with os.scandir(self.fd) as files:
            for count, entry in enumerate(files):
                if count > 4096:
                    raise MediaError("503 Service Unavailable", "Preview storage needs cleanup.")
                if not re.fullmatch(r"[0-9a-f]{64}\.(?:mp4|json|[0-9]+\.(?:mp4|json)\.tmp)", entry.name):
                    continue
                info = entry.stat(follow_symlinks=False)
                if not private_file(info, os.geteuid()):
                    raise MediaError("503 Service Unavailable", "Preview storage is unavailable.")
                total += info.st_size
                entries.append((info.st_mtime, entry.name, info.st_size))
        for modified, name, size in sorted(entries):
            if total <= MAX_CACHE_BYTES - reserve and time.time() - modified < 7 * 86400:
                continue
            os.unlink(name, dir_fd=self.fd)
            total -= size
        if os.fstatvfs(self.fd).f_bavail * os.fstatvfs(self.fd).f_frsize < reserve + 64 * 1024 * 1024:
            raise MediaError("503 Service Unavailable", "Preview storage is low on space.")


def preview_payload(path, state):
    return {"ok": True, **state, "original_url": "/TeslaCam/" + quote(path, safe="/"),
            "preview_url": ("/api/v1/recordings/preview/media?" + urlencode({"path": path})
                            if state["state"] == "ready" else None),
            "max_width": 640, "frames_per_second": 12,
            "max_segment_seconds": MAX_PREVIEW_SECONDS,
            "quality": "low", "live": False}


def preview_status(path, info, request=False, source_fd=None):
    key = fingerprint(path, info)
    try:
        cache = PreviewCache()
    except (OSError, MediaError):
        return preview_payload(path, {"state": "unavailable", "reason": "preview_storage_unavailable"})
    try:
        state = cache.state(key)
        if state["state"] in ("ready", "preparing"):
            return preview_payload(path, state)
        if not all(os.access(binary, os.X_OK) for binary in (FFMPEG, FFPROBE)):
            return preview_payload(path, {"state": "unavailable", "reason": "ffmpeg_not_installed"})
        if not request:
            return preview_payload(path, state)
        import fcntl
        lock = cache.open_file("worker.lock", os.O_RDWR | os.O_CREAT)
        try:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return preview_payload(path, {"state": "unavailable", "reason": "preview_worker_busy", "retry_after_seconds": 5})
            # Another request may have completed while this request opened its source.
            state = cache.state(key)
            if state["state"] == "ready":
                return preview_payload(path, state)
            cache.prune(reserve=MAX_PREVIEW_BYTES)
            cache.write_state(key, "preparing", "preview_preparing")
            try:
                subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "worker",
                                  key, str(source_fd), str(lock)],
                                 pass_fds=(source_fd, lock), start_new_session=True,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, close_fds=True,
                                 env={"PATH": "/usr/bin:/bin", "LANG": "C"})
            except OSError:
                cache.write_state(key, "failed", "preview_start_failed")
            return preview_payload(path, cache.state(key))
        finally:
            # The worker inherits the locked open file description; closing our
            # copy keeps serialization in force until its bounded work exits.
            os.close(lock)
    finally:
        cache.close()


def media_range(value, size):
    if not value:
        return 0, size - 1, "200 OK"
    match = re.fullmatch(r"bytes=([0-9]*)-([0-9]*)", value)
    if not match or not (match[1] or match[2]) or len(value) > 64:
        raise MediaError("416 Range Not Satisfiable", "Request one valid byte range.")
    if match[1]:
        start = int(match[1])
        end = min(int(match[2]) if match[2] else size - 1, size - 1)
    else:
        suffix = int(match[2])
        start, end = max(0, size - suffix), size - 1
    if start < 0 or start > end or start >= size:
        raise MediaError("416 Range Not Satisfiable", "The byte range is outside the preview.")
    return start, end, "206 Partial Content"


def serve_preview(path, info, output=None):
    output = output or sys.stdout.buffer
    cache = PreviewCache()
    try:
        key = fingerprint(path, info)
        if cache.state(key)["state"] != "ready":
            raise MediaError("404 Not Found", "The Low preview is not ready.")
        descriptor = cache.open_file(key + ".mp4")
        try:
            size = os.fstat(descriptor).st_size
            start, end, status = media_range(os.environ.get("HTTP_RANGE", ""), size)
            extra = {"Content-Length": end - start + 1, "Accept-Ranges": "bytes"}
            if status.startswith("206"):
                extra["Content-Range"] = f"bytes {start}-{end}/{size}"
            os.lseek(descriptor, start, os.SEEK_SET)
            headers(status, "video/mp4", extra, output)
            try:
                copy_exact(descriptor, output, end - start + 1)
            except OSError as error:
                raise TransferFailed() from error
        finally:
            os.close(descriptor)
    finally:
        cache.close()


def child_limits():
    import resource
    resource.setrlimit(resource.RLIMIT_CPU, (90, 95))
    resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_PREVIEW_BYTES, MAX_PREVIEW_BYTES))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.nice(15)


def probe_duration(descriptor):
    result = subprocess.run(
        [FFPROBE, "-v", "error", "-max_alloc", "67108864", "-protocol_whitelist", "file,pipe",
         "-enable_drefs", "0", "-use_absolute_path", "0", "-f", "mov",
         "-show_entries", "format=duration", "-of", "json", f"/proc/self/fd/{descriptor}"],
        pass_fds=(descriptor,), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, timeout=10, check=False, preexec_fn=child_limits,
        env={"PATH": "/usr/bin:/bin", "LANG": "C"})
    if result.returncode or len(result.stdout) > 4096:
        raise ValueError("preview_probe_failed")
    value = float(json.loads(result.stdout)["format"]["duration"])
    if not math.isfinite(value) or not 0 < value <= MAX_PREVIEW_SECONDS:
        raise ValueError("preview_segment_too_long")
    return value


def preview_worker(key, source_fd, lock_fd, *, cache_root=CACHE_ROOT, require_readonly=True):
    """Detached bounded process, serialized by an inherited flock descriptor."""
    if not re.fullmatch(r"[0-9a-f]{64}", key):
        return 1
    if not private_file(os.fstat(lock_fd), os.geteuid()):
        return 1
    source_info = os.fstat(source_fd)
    if (not stat.S_ISREG(source_info.st_mode) or
            (require_readonly and not (os.fstatvfs(source_fd).f_flag & os.ST_RDONLY))):
        return 1
    # Explicit fixture injection is only used by direct Python unit tests.
    # The worker CLI never accepts alternate roots or a writable-source flag.
    cache = PreviewCache(cache_root)
    temporary = key + f".{os.getpid()}.mp4.tmp"
    output_fd = None
    try:
        duration = probe_duration(source_fd)
        output_fd = cache.open_file(temporary, os.O_RDWR | os.O_CREAT | os.O_EXCL)
        result = subprocess.run(
            [FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
             "-max_alloc", "67108864", "-threads", "1", "-filter_threads", "1",
             "-protocol_whitelist", "file,pipe", "-enable_drefs", "0", "-use_absolute_path", "0",
             "-f", "mov", "-i", f"/proc/self/fd/{source_fd}", "-map", "0:v:0",
             "-an", "-sn", "-dn", "-vf", "scale='min(640,iw)':-2,fps=12",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast", "-crf", "30", "-threads", "1",
             "-movflags", "+faststart", "-t", str(MAX_PREVIEW_SECONDS),
             "-fs", str(MAX_PREVIEW_BYTES), "-f", "mp4", f"/proc/self/fd/{output_fd}"],
            pass_fds=(source_fd, output_fd), stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=JOB_TIMEOUT - 25, check=False, preexec_fn=child_limits,
            env={"PATH": "/usr/bin:/bin", "LANG": "C"})
        size = os.fstat(output_fd).st_size
        if result.returncode or not 0 < size < MAX_PREVIEW_BYTES:
            raise ValueError("preview_encoding_failed")
        if abs(probe_duration(output_fd) - duration) > 1.5:
            raise ValueError("preview_incomplete")
        os.replace(temporary, key + ".mp4", src_dir_fd=cache.fd, dst_dir_fd=cache.fd)
        cache.write_state(key, "ready", "preview_ready", size_bytes=size, duration_seconds=duration)
    except subprocess.TimeoutExpired:
        cache.write_state(key, "failed", "preview_timed_out")
    except (OSError, ValueError, KeyError, MediaError):
        cache.write_state(key, "failed", "preview_unavailable_for_segment")
    finally:
        if output_fd is not None:
            os.close(output_fd)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=cache.fd)
        cache.close()
        os.close(source_fd)
        os.close(lock_fd)
    return 0


class TransferFailed(Exception):
    pass


@contextlib.contextmanager
def metadata_deadline():
    def expire(_signum, _frame):
        raise MediaError("503 Service Unavailable", "Recording metadata is busy. Retry shortly.")
    previous = signal.signal(signal.SIGALRM, expire)
    signal.setitimer(signal.ITIMER_REAL, 20)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def main(operation):
    streaming = False
    try:
        reader = SourceReader()
        query = os.environ.get("QUERY_STRING", "")
        if operation in ("download", "trash-download"):
            fields = (query_fields(query, {"event", "camera", "segment", "info"}, {"event", "camera"})
                      if operation == "download" else
                      query_fields(query, {"id", "camera", "info"}, {"id", "camera"}))
            if fields.get("info", "1") != "1":
                raise bad_path()
            with metadata_deadline():
                selection = Selection(reader, fields) if operation == "download" else owned_selection(fields)
            try:
                if "info" in fields:
                    json_response(selection.metadata(fields))
                else:
                    streaming = True
                    download(selection)
            finally:
                selection.close()
        elif operation in ("preview-status", "preview-request", "preview-media"):
            fields = query_fields(query, {"path"}, {"path"})
            with metadata_deadline():
                descriptor, info = reader.open(fields["path"])
            try:
                if fields["path"] in reader.restored_paths:
                    if operation == "preview-media":
                        raise MediaError("404 Not Found", "Use the restored original recording.")
                    value = preview_payload(fields["path"], {"state": "unavailable", "reason": "restored_original_only"})
                    value["original_url"] = reader.restored_paths[fields["path"]]
                    json_response(value)
                elif operation == "preview-media":
                    # serve_preview validates state and range before sending headers.
                    serve_preview(fields["path"], info)
                else:
                    value = preview_status(fields["path"], info,
                                           request=(operation == "preview-request"), source_fd=descriptor)
                    json_response(value, "202 Accepted" if value["state"] == "preparing" else "200 OK")
            finally:
                os.close(descriptor)
        else:
            raise MediaError("404 Not Found", "Unknown recording media operation.")
    except (BrokenPipeError, ConnectionResetError):
        # A cancelled browser transfer must stop reads immediately, not continue
        # building an archive or append JSON to a truncated media response.
        return 0
    except TransferFailed:
        return 1
    except MediaError as error:
        if streaming:
            return 1
        json_response({"ok": False, "error": str(error)}, error.status)
    except OSError:
        if streaming:
            return 1
        json_response({"ok": False, "error": "The recording or preview is no longer available. Refresh the clip list."}, "404 Not Found")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "worker":
        sys.exit(preview_worker(sys.argv[2], int(sys.argv[3]), int(sys.argv[4])))
    sys.exit(main(sys.argv[1] if len(sys.argv) == 2 else ""))
