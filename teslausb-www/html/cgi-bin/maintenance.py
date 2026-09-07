"""Read-only maintenance metadata and fixed log downloads.

The unprivileged CGI wrapper applies the shared host/method gate. One fixed
sudo action obtains bounded root-only health metadata, never recording data.
No password, key, sshd configuration, arbitrary path, or shell-command API exists.
"""

import errno
import contextlib
import datetime
import json
import os
from pathlib import PurePosixPath
import re
import signal
import stat
import subprocess
import sys
import time


MAX_LOG_BYTES = 8 * 1024 * 1024
HEALTH_LOG_BYTES = 256 * 1024
MAX_HEALTH_BYTES = 65536
MAX_HEALTH_ENTRIES = 4096
RECOVERY_NOTE = "Shared reflink extents may be counted more than once; this is not reclaimable space."
LOGS = {
    "diagnostics": ("/tmp/diagnostics.txt", "diagnostics.txt"),
    "archiveloop": ("/mutable/archiveloop.log", "archiveloop.log"),
    "setup": ("/teslausb/teslausb-headless-setup.log", "teslausb-headless-setup.log"),
    "maintenance": ("/teslausb/teslausb-runtime-maintenance.log", "teslausb-runtime-maintenance.log"),
}
ENABLED_STATES = frozenset((
    "enabled", "enabled-runtime", "disabled", "static", "indirect", "masked",
    "masked-runtime", "generated", "transient", "linked", "linked-runtime", "alias",
))


def ssh_status():
    """Report service state, not network reachability or authentication success.

Reading sshd's private configuration or probing an unattributed TCP listener
would not establish the effective login endpoint. Port 22 is expressly only a
default suggestion, including when an administrator uses a custom SSH port.
"""
    result = {
        "service_state": "unknown", "enabled_state": "unknown",
        "port": None, "port_source": "unknown",
    }
    try:
        query = subprocess.run(
            ["/usr/bin/systemctl", "show", "ssh.service", "--no-pager",
             "--property=LoadState,ActiveState,UnitFileState"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=2, check=False, encoding="utf-8", errors="replace",
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C",
                 "SYSTEMD_PAGER": "", "SYSTEMD_COLORS": "0"},
        )
    except (OSError, subprocess.SubprocessError):
        return result
    if query.returncode != 0 or len(query.stdout) > 4096:
        return result
    properties = {}
    for line in query.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator and key in ("LoadState", "ActiveState", "UnitFileState"):
            if key in properties:
                return result
            properties[key] = value
    load_state = properties.get("LoadState")
    if load_state == "not-found":
        result["service_state"] = "not-installed"
        return result
    if load_state not in ("loaded", "masked"):
        return result
    active_state = properties.get("ActiveState")
    if active_state in ("active", "inactive", "failed"):
        result["service_state"] = active_state
        result["port"] = 22
        result["port_source"] = "default"
    enabled = properties.get("UnitFileState")
    if enabled in ENABLED_STATES:
        result["enabled_state"] = enabled
    return result


class LogUnavailable(Exception):
    def __init__(self, reason="unavailable"):
        self.reason = reason


class HealthExpired(Exception):
    pass


class LogReader:
    """Open fixed files through pinned directory descriptors without symlinks.

    The only permitted alias is root-owned /teslausb -> /boot[/firmware]. Its
    resolved components are still opened with O_NOFOLLOW. Tests may supply an
    isolated root and UID; main never accepts those values from CGI or argv.
    """

    def __init__(self, root="/", root_uid=0, web_uid=None):
        self.root = root
        self.root_uid = root_uid
        self.web_uid = os.geteuid() if web_uid is None else web_uid

    def _directory(self, fd, name, *, temporary=False):
        next_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                          dir_fd=fd)
        info = os.fstat(next_fd)
        safe_write = not (info.st_mode & 0o022)
        # /tmp is intentionally sticky/world-writable; the final file must
        # still have the expected owner, one link, and safe permissions.
        if temporary:
            safe_write = safe_write or bool(info.st_mode & stat.S_ISVTX)
        if info.st_uid != self.root_uid or not safe_write:
            os.close(next_fd)
            raise LogUnavailable()
        return next_fd

    def _path(self, fd, path):
        if not path.startswith("/teslausb/"):
            return PurePosixPath(path).parts[1:]
        alias = os.stat("teslausb", dir_fd=fd, follow_symlinks=False)
        if not stat.S_ISLNK(alias.st_mode) or alias.st_uid != self.root_uid:
            raise LogUnavailable()
        target = os.readlink("teslausb", dir_fd=fd)
        # Accept the normal absolute link and its equivalent relative form,
        # but do not normalize traversal, secondary aliases, or arbitrary paths.
        if target not in ("/boot", "/boot/firmware", "boot", "boot/firmware"):
            raise LogUnavailable()
        return (*PurePosixPath("/" + target.lstrip("/")).parts[1:],
                PurePosixPath(path).name)

    def open(self, log_id):
        if log_id not in LOGS:
            raise LogUnavailable()
        directory_fd = None
        file_fd = None
        try:
            directory_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            root_info = os.fstat(directory_fd)
            if root_info.st_uid != self.root_uid or root_info.st_mode & 0o022:
                raise LogUnavailable()
            parts = self._path(directory_fd, LOGS[log_id][0])
            for index, part in enumerate(parts[:-1]):
                next_fd = self._directory(directory_fd, part,
                                          temporary=(index == 0 and part == "tmp"))
                os.close(directory_fd)
                directory_fd = next_fd
            file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                              dir_fd=directory_fd)
            info = os.fstat(file_fd)
            expected_uid = self.web_uid if log_id == "diagnostics" else self.root_uid
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
                    info.st_uid != expected_uid or info.st_mode & 0o022):
                raise LogUnavailable()
            result_fd = file_fd
            file_fd = None
            return result_fd, info.st_size
        except OSError as error:
            reason = "missing" if error.errno == errno.ENOENT else "unavailable"
            raise LogUnavailable(reason) from None
        finally:
            if file_fd is not None:
                os.close(file_fd)
            if directory_fd is not None:
                os.close(directory_fd)

    def metadata(self, log_id):
        try:
            fd, size = self.open(log_id)
            os.close(fd)
        except LogUnavailable as error:
            return {"available": False, "reason": error.reason,
                    "size_bytes": None, "truncated": False}
        return {"available": True, "reason": "available", "size_bytes": size,
                "truncated": size > MAX_LOG_BYTES}

    def read(self, log_id):
        fd, size = self.open(log_id)
        try:
            os.lseek(fd, max(0, size - MAX_LOG_BYTES), os.SEEK_SET)
            # Bound both growth while reading and memory; a rotation keeps
            # this pinned inode. Concurrent truncation may return fewer bytes.
            chunks = []
            remaining = min(size, MAX_LOG_BYTES)
            while remaining:
                chunk = os.read(fd, min(remaining, 65536))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            return b"".join(chunks), size
        except OSError:
            raise LogUnavailable() from None
        finally:
            os.close(fd)


def health_defaults():
    filesystem = {"available": False, "total_bytes": None, "free_bytes": None,
                  "available_bytes": None}
    return {
        "schema_version": 1,
        "storage": {"backing": {**filesystem, "cleanup_reserve_bytes": None,
                                "below_cleanup_reserve": None},
                    "mutable": dict(filesystem),
                    "live_camera": {"available": False, "reason": "not_inspected"}},
        "read_only": {"root": None, "boot": None},
        "snapshots": {"available": False, "scan_complete": False,
                      "completed_count": None, "last_completed": None},
        "cleanup": {"available": False, "evidence": "unavailable",
                    "last_attempt_at_utc": None, "last_released_at_utc": None,
                    "last_released_snapshot": None, "tail_limited": True},
        "clock": {"available": False, "state": None, "last_verified_utc": None,
                  "observed_utc": None, "age_seconds": None, "fallback_utc": None},
        "recovery": {"available": False, "scan_complete": False, "items": [],
                     "total_logical_bytes": None, "total_allocated_bytes": None,
                     "allocation_note": RECOVERY_NOTE},
    }


def utc_timestamp(epoch):
    if not isinstance(epoch, (int, float)) or not 1577836800 <= epoch < 4102444800:
        return None
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat(timespec="seconds")


def valid_utc(value):
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        stamp = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return utc_timestamp(stamp.timestamp()) if stamp.tzinfo is not None else None
    except (ValueError, OverflowError):
        return None


class HealthReader(LogReader):
    """Root-only, fixed-scope metadata. Never open a recording's contents."""

    @contextlib.contextmanager
    def directory(self, path):
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if info.st_uid != self.root_uid or info.st_mode & 0o022:
                raise LogUnavailable()
            for part in PurePosixPath(path).parts[1:]:
                next_fd = self._directory(fd, part)
                os.close(fd)
                fd = next_fd
            yield fd
        finally:
            os.close(fd)

    def regular_info(self, fd, name):
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != self.root_uid
                or info.st_nlink != 1 or info.st_mode & 0o022):
            raise LogUnavailable()
        return info

    def small_file(self, fd, name, limit):
        file_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        try:
            info = os.fstat(file_fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != self.root_uid
                    or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size > limit):
                raise LogUnavailable()
            data = os.read(file_fd, limit + 1)
            if len(data) > limit:
                raise LogUnavailable()
            return data
        finally:
            os.close(file_fd)


def filesystem_health(reader, path, reserve=False):
    with reader.directory("/") as root_fd:
        root_device = os.fstat(root_fd).st_dev
    with reader.directory(path) as fd:
        if os.fstat(fd).st_dev == root_device:
            # These are dedicated data filesystems in the supported layout.
            # An unmounted placeholder must not report root free space as SD
            # recording/backing capacity. No mount is attempted to fix it.
            raise LogUnavailable()
        usage = os.fstatvfs(fd)
        # f_bfree, not f_bavail, matches freespacemanager/manage_free_space.
        total, free, available = (value * usage.f_frsize for value in
                                  (usage.f_blocks, usage.f_bfree, usage.f_bavail))
        value = {"available": True, "total_bytes": total, "free_bytes": free,
                 "available_bytes": available}
        if reserve:
            image = reader.regular_info(fd, "cam_disk.bin")
            if image.st_dev != os.fstat(fd).st_dev:
                raise LogUnavailable()
            threshold = 10737418240 + total // 33
            value.update(cleanup_reserve_bytes=threshold, below_cleanup_reserve=free < threshold)
        return value


def completed_snapshots(reader):
    count, newest, seen = 0, None, 0
    with reader.directory("/backingfiles/snapshots") as fd, os.scandir(fd) as entries:
        for entry in entries:
            seen += 1
            if seen > MAX_HEALTH_ENTRIES:
                raise LogUnavailable()
            if not re.fullmatch(r"snap-[0-9]{6}", entry.name):
                continue
            child = reader._directory(fd, entry.name)
            try:
                reader.regular_info(child, "snap.bin")
                try:
                    toc = reader.regular_info(child, "snap.bin.toc")
                except FileNotFoundError:
                    continue  # An in-progress .toc_ is not completion evidence.
                count += 1
                if newest is None or entry.name > newest["name"]:
                    newest = {"name": entry.name, "completed_at_utc": utc_timestamp(toc.st_mtime),
                              "time_source": "toc_mtime"}
            finally:
                os.close(child)
    return {"available": True, "scan_complete": True,
            "completed_count": count, "last_completed": newest}


def cleanup_evidence(data):
    result = health_defaults()["cleanup"]
    result.update(available=True, evidence="none_in_log_tail")
    # Historical log prefixes are locale-dependent: report evidence but do
    # not guess their UTC offset. New release markers carry explicit UTC.
    pattern = re.compile(r"^(.{0,100}?): ?"
                         r"(releasing snapshot /backingfiles/snapshots/|released snapshot )"
                         r"(snap-[0-9]{6})(?: at ([0-9T:.+Z-]+))?$")
    for line in data.decode("utf-8", "replace").splitlines():
        match = pattern.fullmatch(line)
        if not match:
            continue
        timestamp = valid_utc(match[4] or match[1].strip())
        if match[2].startswith("releasing"):
            result["last_attempt_at_utc"] = timestamp
            if result["evidence"] != "completed_release":
                result["evidence"] = "release_attempt"
        else:
            result.update(evidence="completed_release", last_released_at_utc=timestamp,
                          last_released_snapshot=match[3])
    return result


def clock_health(reader):
    with reader.directory("/run/teslausb-time") as fd:
        value = json.loads(reader.small_file(fd, "status.json", 4096))
    if (not isinstance(value, dict) or value.get("schema") != 1
            or value.get("state") not in ("synchronized", "waiting_for_network_time")
            or type(value.get("uptime_seconds")) not in (int, float)
            or not 0 <= value["uptime_seconds"] <= time.monotonic()):
        raise LogUnavailable()
    result = {key: valid_utc(value.get(key)) for key in
              ("last_verified_utc", "observed_utc", "fallback_utc")}
    if result["observed_utc"] is None:
        raise LogUnavailable()
    result.update(available=True, state=value["state"],
                  age_seconds=round(time.monotonic() - value["uptime_seconds"], 1))
    return result


def recovery_inventory(reader):
    items, seen = [], 0
    with reader.directory("/backingfiles") as fd, os.scandir(fd) as entries:
        for entry in entries:
            seen += 1
            if seen > MAX_HEALTH_ENTRIES:
                raise LogUnavailable()
            if not re.fullmatch(r"maintenance-recovery-[A-Za-z0-9_-]{1,64}", entry.name):
                continue
            if len(items) >= 64:
                raise LogUnavailable()
            child = reader._directory(fd, entry.name)
            count = logical = allocated = 0
            try:
                # Recovery bundles are flat. Unknown subdirectories/aliases
                # make totals unavailable rather than triggering recursion.
                with os.scandir(child) as members:
                    for member in members:
                        seen += 1
                        if seen > MAX_HEALTH_ENTRIES:
                            raise LogUnavailable()
                        info = reader.regular_info(child, member.name)
                        count += 1
                        logical += info.st_size
                        allocated += info.st_blocks * 512
                items.append({"name": entry.name, "file_count": count,
                              "logical_bytes": logical, "allocated_bytes": allocated})
            finally:
                os.close(child)
    return {"available": True, "scan_complete": True, "items": sorted(items, key=lambda item: item["name"]),
            "total_logical_bytes": sum(item["logical_bytes"] for item in items),
            "total_allocated_bytes": sum(item["allocated_bytes"] for item in items),
            "allocation_note": RECOVERY_NOTE}


def readonly_mounts(text):
    mounts = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 7 and fields[4] in ("/", "/boot", "/boot/firmware"):
            options = fields[5].split(",")
            mounts[fields[4]] = True if "ro" in options else False if "rw" in options else None
    return {"root": mounts.get("/"), "boot": mounts.get("/boot/firmware", mounts.get("/boot"))}


def collect_health(reader=None):
    reader = reader or HealthReader()
    result = health_defaults()
    tasks = ((result["storage"], "backing", lambda: filesystem_health(reader, "/backingfiles", True)),
             (result["storage"], "mutable", lambda: filesystem_health(reader, "/mutable")),
             (result, "snapshots", lambda: completed_snapshots(reader)),
             (result, "clock", lambda: clock_health(reader)),
             (result, "recovery", lambda: recovery_inventory(reader)))
    for target, key, collect in tasks:
        try:
            target[key] = collect()
        except (OSError, LogUnavailable, ValueError, TypeError):
            pass
    try:
        fd, size = reader.open("archiveloop")
        try:
            os.lseek(fd, max(0, size - HEALTH_LOG_BYTES), os.SEEK_SET)
            result["cleanup"] = cleanup_evidence(os.read(fd, min(size, HEALTH_LOG_BYTES)))
        finally:
            os.close(fd)
    except (OSError, LogUnavailable):
        pass
    try:
        with open("/proc/self/mountinfo", encoding="ascii") as source:
            result["read_only"] = readonly_mounts(source.read(131072))
    except OSError:
        pass
    return result


def privileged_health():
    """Invoke the sole fixed root action; never forward request/environment data."""
    try:
        query = subprocess.run(
            ["/usr/bin/sudo", "-n", "/usr/local/sbin/teslausb-web-sudo", "maintenance-health"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=6, check=False, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"})
        if query.returncode or len(query.stdout) > MAX_HEALTH_BYTES:
            return health_defaults()
        value = json.loads(query.stdout)
        # Fixed root-owned helper is the trust boundary. Require the exact
        # bounded top-level schema before forwarding its allowlisted metadata.
        if not valid_health(value):
            return health_defaults()
        return value
    except (OSError, subprocess.SubprocessError, ValueError, TypeError):
        return health_defaults()


def valid_health(value):
    """Reject extra fields and wrong types, even from the fixed helper."""
    def keys(item, expected):
        return type(item) is dict and set(item) == set(expected)

    def number(item):
        return item is None or type(item) is int and 0 <= item < 2 ** 64

    def flag(item):
        return item is None or type(item) is bool

    def stamp(item):
        return item is None or type(item) is str and valid_utc(item) == item

    defaults = health_defaults()
    if (not keys(value, defaults) or type(value["schema_version"]) is not int
            or value["schema_version"] != 1):
        return False
    try:
        if not keys(value["storage"], defaults["storage"]):
            return False
        for name in ("backing", "mutable"):
            item = value["storage"][name]
            if (not keys(item, defaults["storage"][name]) or type(item["available"]) is not bool
                    or any(not number(item[key]) for key in item if key.endswith("_bytes"))):
                return False
        if (not flag(value["storage"]["backing"]["below_cleanup_reserve"])
                or value["storage"]["live_camera"] != defaults["storage"]["live_camera"]
                or not keys(value["read_only"], ("root", "boot"))
                or any(not flag(item) for item in value["read_only"].values())):
            return False
        for name in ("snapshots", "cleanup", "clock", "recovery"):
            if not keys(value[name], defaults[name]) or type(value[name]["available"]) is not bool:
                return False
        snapshots = value["snapshots"]
        latest = snapshots["last_completed"]
        if (type(snapshots["scan_complete"]) is not bool or not number(snapshots["completed_count"])
                or latest is not None and (
                    not keys(latest, ("name", "completed_at_utc", "time_source"))
                    or not re.fullmatch(r"snap-[0-9]{6}", latest["name"])
                    or not stamp(latest["completed_at_utc"]) or latest["time_source"] != "toc_mtime")):
            return False
        cleanup = value["cleanup"]
        if (cleanup["evidence"] not in ("completed_release", "release_attempt", "none_in_log_tail", "unavailable")
                or cleanup["tail_limited"] is not True
                or not stamp(cleanup["last_attempt_at_utc"]) or not stamp(cleanup["last_released_at_utc"])
                or cleanup["last_released_snapshot"] is not None and
                not re.fullmatch(r"snap-[0-9]{6}", cleanup["last_released_snapshot"])):
            return False
        clock = value["clock"]
        if (clock["state"] not in (None, "synchronized", "waiting_for_network_time")
                or any(not stamp(clock[key]) for key in ("last_verified_utc", "observed_utc", "fallback_utc"))
                or clock["age_seconds"] is not None and (
                    type(clock["age_seconds"]) not in (int, float) or not 0 <= clock["age_seconds"] < 2 ** 64)):
            return False
        recovery = value["recovery"]
        if (type(recovery["scan_complete"]) is not bool or type(recovery["items"]) is not list
                or len(recovery["items"]) > 64 or recovery["allocation_note"] != RECOVERY_NOTE
                or not number(recovery["total_logical_bytes"]) or not number(recovery["total_allocated_bytes"])):
            return False
        for item in recovery["items"]:
            if (not keys(item, ("name", "file_count", "logical_bytes", "allocated_bytes"))
                    or not re.fullmatch(r"maintenance-recovery-[A-Za-z0-9_-]{1,64}", item["name"])
                    or any(type(item[key]) is not int or not number(item[key])
                           for key in ("file_count", "logical_bytes", "allocated_bytes"))):
                return False
        return True
    except (KeyError, TypeError):
        return False


def health_main():
    if os.geteuid() != 0:
        return 77
    def expired(_signum, _frame):
        raise HealthExpired()
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(4)
    try:
        value = collect_health()
    except HealthExpired:
        value = health_defaults()
    finally:
        signal.alarm(0)
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    return 0


def response(status, body, content_type="application/json; charset=utf-8", extra=()):
    headers = ["Status: " + status, "Content-Type: " + content_type,
               "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
               "Referrer-Policy: same-origin", "X-TeslaUSB-API-Version: 1",
               "Content-Length: " + str(len(body)), *extra]
    return ("\r\n".join(headers) + "\r\n\r\n").encode("ascii") + body


def json_response(status, data):
    return response(status, (json.dumps(data, separators=(",", ":")) + "\n").encode("utf-8"))


def handle(operation, reader=None):
    reader = reader if reader is not None else LogReader()
    if operation == "status":
        return json_response("200 OK", {
            "schema_version": 1, "ssh": ssh_status(),
            "health": privileged_health(),
            "logs": {name: reader.metadata(name) for name in LOGS},
        })
    if operation not in LOGS:
        return json_response("404 Not Found", {"ok": False, "error": "Unknown maintenance route."})
    try:
        body, size = reader.read(operation)
    except LogUnavailable as error:
        missing = error.reason == "missing"
        return json_response("404 Not Found" if missing else "503 Service Unavailable", {
            "ok": False, "error": "The saved log is missing." if missing else
            "The saved log is not safely readable by the web service.",
        })
    return response("200 OK", body, "text/plain; charset=utf-8", (
        'Content-Disposition: attachment; filename="' + LOGS[operation][1] + '"',
        "X-TeslaUSB-Truncated: " + ("true" if size > MAX_LOG_BYTES else "false"),
        "X-TeslaUSB-Original-Size: " + str(size),
    ))


if __name__ == "__main__":
    # The wrapper passes exactly one allowlisted operation. Invalid direct
    # invocation cannot select another file or subprocess.
    if sys.argv[1:] == ["health"]:
        raise SystemExit(health_main())
    sys.stdout.buffer.write(handle(sys.argv[1] if len(sys.argv) == 2 else ""))
