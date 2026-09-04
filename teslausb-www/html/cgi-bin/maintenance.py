"""Unprivileged, read-only maintenance metadata and fixed log downloads.

Invoked only by maintenance.sh, which applies the shared CGI host/method gate.
No password, key, sshd configuration, arbitrary path, or shell-command API exists.
"""

import errno
import json
import os
from pathlib import PurePosixPath
import stat
import subprocess
import sys


MAX_LOG_BYTES = 8 * 1024 * 1024
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
    sys.stdout.buffer.write(handle(sys.argv[1] if len(sys.argv) == 2 else ""))
