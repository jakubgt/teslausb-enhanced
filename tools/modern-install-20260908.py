#!/usr/bin/python3
"""Fixed-path, reversible modern UI update; invoke on the Pi only after review.

--check PACKAGE_JSON validates without remounting or publishing installed files.
--install PACKAGE_JSON backs up, publishes atomically, and reloads nginx/systemd.
Neither mode starts/stops USB, archive, power, or cleanup services. A failed or
interrupted transaction leaves runtime-maintenance.pending for manual recovery.
"""

import argparse
import base64
import binascii
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid


BASE = Path("/mutable/teslausb/manual-fixes")
PENDING = BASE / "runtime-maintenance.pending"
PRIVATE = ("/backingfiles/teslausb-recording-trash", "/backingfiles/teslausb-previews")
LEGACY = ("/mutable/teslausb-recording-trash", "/mutable/teslausb-previews")
MODERN = Path("/var/www/html/modern")
NGINX_SITE = "/etc/nginx/sites-available/teslausb.nginx"
SUDOERS = "/etc/sudoers.d/010_www-data-nopasswd"
TIMER = "teslausb-trash-cleanup.timer"
SERVICE = "teslausb-trash-cleanup.service"
MAX_FILE = 8 * 1024 * 1024
MAX_PACKAGE = 24 * 1024 * 1024
ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C", "LC_ALL": "C",
       "PYTHONDONTWRITEBYTECODE": "1"}
DESTINATIONS = {"/var/www/html/modern/" + name: 0o644 for name in (
    "app.mjs", "connection.css", "connection.mjs", "device.css", "device.js",
    "files.js", "index.html", "model.mjs", "player-nav.css", "player.mjs",
    "style.css", "thumbnail-loader.mjs", "trash.css", "trash.js")}
DESTINATIONS.update({"/var/www/html/cgi-bin/" + name: mode for name, mode in (
    ("api-v1.sh", 0o755), ("recording-media.py", 0o644),
    ("recording-media.sh", 0o755), ("recording-trash.py", 0o644),
    ("recording-trash.sh", 0o755), ("shutdown.sh", 0o755))})
DESTINATIONS.update({
    "/var/www/html/index.html": 0o644,
    "/usr/local/sbin/teslausb-web-sudo": 0o755,
    SUDOERS: 0o440, NGINX_SITE: 0o644,
    "/etc/systemd/system/" + SERVICE: 0o644,
    "/etc/systemd/system/" + TIMER: 0o644,
    "/root/bin/archive-common.sh": 0o755,
})
COMMANDS = {name: next((path for path in paths if os.path.isfile(path) and os.access(path, os.X_OK)), None)
            for name, paths in {
                "bash": ("/usr/bin/bash", "/bin/bash"),
                "findmnt": ("/usr/bin/findmnt", "/bin/findmnt"),
                "mount": ("/usr/bin/mount", "/bin/mount"),
                "systemctl": ("/usr/bin/systemctl", "/bin/systemctl"),
                "nginx": ("/usr/sbin/nginx",), "visudo": ("/usr/sbin/visudo",),
            }.items()}


class InstallError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise InstallError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Package contains duplicate JSON keys")
        result[key] = value
    return result


def command(name, *arguments, allowed=(0,)):
    require(COMMANDS[name] is not None, "Required system tool is unavailable: " + name)
    result = subprocess.run([COMMANDS[name], *arguments], capture_output=True,
                            text=True, env=ENV, timeout=30)
    # Do not echo configuration, credentials, subprocess stdout, or stderr.
    require(result.returncode in allowed, name + " failed (exit " + str(result.returncode) + ")")
    return result.stdout.strip()


def safe_directory(path, *, missing=False):
    path = Path(path)
    for component in reversed((path, *path.parents)):
        try:
            info = component.lstat()
        except FileNotFoundError:
            require(missing, "Required directory is absent: " + str(component))
            continue
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
                "Unsafe directory: " + str(component))


def read_regular(path, *, check_parents=True, absent=False):
    path = Path(path)
    if check_parents:
        safe_directory(path.parent, missing=absent)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        require(absent, "Required file is absent: " + str(path))
        return None, None
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == 0
                and info.st_gid == 0 and not info.st_mode & 0o022,
                "Unsafe file ownership, links, or mode: " + str(path))
        require(info.st_size <= MAX_PACKAGE, "File is too large: " + str(path))
        data = source.read(MAX_PACKAGE + 1)
        after = os.fstat(source.fileno())
        require(len(data) <= MAX_PACKAGE and (info.st_size, info.st_mtime_ns) ==
                (after.st_size, after.st_mtime_ns), "File changed while being read")
        return data, {"sha256": digest(data), "mode": stat.S_IMODE(info.st_mode),
                      "uid": info.st_uid, "gid": info.st_gid}


def parse_package(data):
    require(len(data) <= MAX_PACKAGE, "Package is too large")
    value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    require(isinstance(value, dict) and set(value) <= {
        "schema_version", "expected_boot_id", "source_commit", "files", "private_directories"},
        "Unsupported package fields")
    require(type(value.get("schema_version")) is int and value["schema_version"] == 1,
            "Unsupported package schema")
    require(isinstance(value.get("expected_boot_id"), str) and re.fullmatch(
        r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value["expected_boot_id"]), "Invalid expected boot ID")
    require(value.get("source_commit") is None or (isinstance(value["source_commit"], str)
            and re.fullmatch(r"[0-9a-f]{40}", value["source_commit"])), "Invalid source commit")
    require(isinstance(value.get("files"), list) and 1 <= len(value["files"]) <= len(DESTINATIONS),
            "Invalid package file count")
    require(isinstance(value.get("private_directories", []), list) and
            len(set(value.get("private_directories", []))) == len(value.get("private_directories", [])) and
            all(path in PRIVATE for path in value.get("private_directories", [])), "Unexpected private directory")
    seen = set()
    for item in value["files"]:
        require(isinstance(item, dict) and set(item) == {"path", "data_b64", "sha256", "before"},
                "Invalid package file fields")
        path = item["path"]
        require(isinstance(path, str) and path in DESTINATIONS and path not in seen, "Unexpected or duplicate destination")
        seen.add(path)
        require(isinstance(item["data_b64"], str) and isinstance(item["sha256"], str), "Invalid file encoding")
        try:
            content = base64.b64decode(item["data_b64"], validate=True)
        except (ValueError, binascii.Error) as error:
            raise InstallError("Invalid base64 file content") from error
        require(0 < len(content) <= MAX_FILE and digest(content) == item["sha256"], "Package file hash mismatch")
        content.decode("utf-8")
        require(b"\r" not in content and b"\x00" not in content, "Package files must be LF-only UTF-8 text")
        before = item["before"]
        require(before is None or (isinstance(before, dict) and set(before) == {"sha256", "mode", "uid", "gid"}
                and isinstance(before["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", before["sha256"])
                and type(before["mode"]) is int and 0 <= before["mode"] <= 0o7777
                and type(before["uid"]) is int and before["uid"] == 0
                and type(before["gid"]) is int and before["gid"] == 0), "Invalid prior-file expectation")
        item["content"] = content
    return value


def root_mode():
    options = command("findmnt", "-n", "-o", "OPTIONS", "--mountpoint", "/").split(",")
    require(("ro" in options) != ("rw" in options), "Cannot establish root mount mode")
    return "ro" if "ro" in options else "rw"


def runtime_state():
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    service = command("systemctl", "show", "teslausb", "-p", "ActiveState", "-p", "NRestarts",
                      "-p", "ExecMainStartTimestampMonotonic")
    require("ActiveState=active" in service, "TeslaUSB recording service is not active")
    gadget = Path("/sys/kernel/config/usb_gadget/teslausb")
    udc = (gadget / "UDC").read_text().strip()
    require(bool(udc), "USB gadget is not bound")
    luns = {path.parent.name: path.read_text().strip() for path in
            sorted((gadget / "functions/mass_storage.0").glob("lun.*/file"))}
    require(luns.get("lun.0") == "/backingfiles/cam_disk.bin", "Camera LUN is not attached as expected")
    gadget_state = {path.parent.name: path.read_text().strip()
                    for path in sorted(Path("/sys/class/udc").glob("*/state"))}
    require(gadget_state and all(value == "configured" for value in gadget_state.values()),
            "USB gadget must be configured by the car before installation")
    return {"boot": boot, "service": service, "udc": udc, "luns": luns, "gadget": gadget_state}


def storage_preflight(package, originals):
    root_device = os.stat("/").st_dev
    for target, filesystems in (("/backingfiles", {"ext4", "xfs", "btrfs"}),
                               ("/mutable", {"ext4", "xfs", "btrfs"})):
        safe_directory(target)
        mounts = json.loads(command("findmnt", "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS",
                                    "--mountpoint", target)).get("filesystems", [])
        require(len(mounts) == 1, "A real recording-data mount is required: " + target)
        mount = mounts[0]
        require(mount.get("target") == target and mount.get("fstype") in filesystems and
                "rw" in mount.get("options", "").split(",") and
                str(mount.get("source", "")).startswith("/dev/") and
                os.stat(target).st_dev != root_device, "Unexpected or read-only data mount: " + target)
    payload_bytes = sum(len(item["content"]) for item in package["files"])
    backup_bytes = sum(len(content) for content in originals.values() if content is not None)
    for target, required in (("/", payload_bytes + MAX_FILE),
                             ("/mutable", backup_bytes + 1024 * 1024),
                             ("/backingfiles", 1024 * 1024),
                             (tempfile.gettempdir(), payload_bytes + 1024 * 1024)):
        require(shutil.disk_usage(target).free >= required, "Insufficient staging/backup space on " + target)


def cleanup_state():
    # An active cleanup timer could expire data during installation. This
    # installer neither pauses nor starts it: scheduling remains with the caller.
    result = {}
    for unit in (SERVICE, TIMER):
        properties = command("systemctl", "show", unit, "-p", "ActiveState", "-p", "SubState",
                             "-p", "UnitFileState", "-p", "LoadState", allowed=(0, 1))
        result[unit] = dict(line.split("=", 1) for line in properties.splitlines() if "=" in line)
        require(result[unit].get("ActiveState") in {"inactive", "failed"}, "Cleanup unit must be inactive: " + unit)
    return result


def no_root_writers():
    root_device = os.stat("/").st_dev
    for process in Path("/proc").glob("[0-9]*"):
        try:
            descriptors = list((process / "fd").iterdir())
        except FileNotFoundError:
            continue
        for descriptor in descriptors:
            try:
                info = descriptor.stat()
                if info.st_dev == root_device and stat.S_ISREG(info.st_mode):
                    flags = next(int(line.split()[1], 8) for line in
                                 (process / "fdinfo" / descriptor.name).read_text().splitlines()
                                 if line.startswith("flags:"))
                    require(not flags & 3, "Root filesystem has a writable descriptor in PID " + process.name)
            except FileNotFoundError:
                continue


def private_state(package):
    import pwd
    user = pwd.getpwnam("www-data")
    for path in LEGACY:
        target = Path(path)
        if os.path.lexists(target):
            info = target.lstat()
            require(stat.S_ISDIR(info.st_mode), "Unsafe legacy recording store")
            require(not any(target.iterdir()), "Legacy recording store contains data; separate migration is required")
    result = []
    for path in package.get("private_directories", []):
        target = Path(path)
        safe_directory(target.parent)
        if os.path.lexists(target):
            info = target.lstat()
            require(stat.S_ISDIR(info.st_mode) and info.st_uid == user.pw_uid and info.st_gid == user.pw_gid
                    and stat.S_IMODE(info.st_mode) == 0o700, "Unsafe existing private directory: " + path)
        else:
            result.append(path)
    return user, result


def validate_preconditions(package):
    require(os.geteuid() == 0, "Run through sudo on the reviewed Pi")
    require(not os.path.lexists(PENDING), "A runtime maintenance transaction is pending")
    # This dated installer publishes one reviewed release, not arbitrary deltas.
    # The Classic link is optional; every modern/runtime dependency is required.
    required = set(DESTINATIONS) - {"/var/www/html/index.html"}
    require(required <= {item["path"] for item in package["files"]}, "Package omits required release files")
    require(set(package.get("private_directories", [])) == set(PRIVATE), "Both private recording stores are required")
    for dependency in ("cgi-common.sh", "maintenance.py", "status.sh", "videolist.sh"):
        read_regular("/var/www/html/cgi-bin/" + dependency)
    state = runtime_state()
    require(state["boot"] == package["expected_boot_id"], "Device boot changed after package preparation")
    originals = {}
    for item in package["files"]:
        content, metadata = read_regular(item["path"], absent=True)
        require(metadata == item["before"], "Prior file differs: " + item["path"])
        parent = Path(item["path"]).parent
        require(parent.exists() or parent == MODERN, "Unexpected missing destination parent")
        originals[item["path"]] = content
        if item["path"] == "/var/www/html/index.html":
            addition = b'    <a href="/modern/" class="githublink">Modern UI</a>\n'
            require(content is not None and item["content"].count(addition) == 1
                    and item["content"].replace(addition, b"", 1) == content,
                    "Classic index update must only add the Modern UI link")
        if item["path"] == NGINX_SITE:
            validate_nginx_additions(content, item["content"])
    private_state(package)
    storage_preflight(package, originals)
    safe_directory(BASE, missing=True)
    no_root_writers()
    return state, originals, cleanup_state(), root_mode()


def validate_nginx_additions(before, after):
    require(before is not None, "An existing rendered nginx site is required")
    blocks = (
        'location = / { try_files /modern/index.html =404; }',
        'location ~ ^/modern/.*\\.mjs$ { try_files $uri =404; types { application/javascript mjs; } }',
        'location ~ ^/cgi-bin/.*\\.py(?:/|$) { deny all; }',
    )
    def normalized(content):
        text = re.sub(r"(?m)^\s*#.*$", "", content.decode("utf-8"))
        return re.sub(r"\s+", " ", text).strip()
    old, new = normalized(before), normalized(after)
    for block in blocks:
        require(new.count(block) == 1 and old.count(block) <= 1,
                "Nginx update must contain each exact trusted modern location once")
        old, new = old.replace(block, ""), new.replace(block, "")
    require(re.sub(r"\s+", " ", old).strip() == re.sub(r"\s+", " ", new).strip(),
            "Nginx update changes existing authentication, hosts, or other settings")


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic(path, content, mode, uid=0, gid=0):
    path = Path(path)
    safe_directory(path.parent)
    descriptor, temporary = tempfile.mkstemp(prefix=".modern-install-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as target:
            target.write(content)
            target.flush()
            os.fchown(target.fileno(), uid, gid)
            os.fchmod(target.fileno(), mode)
            os.fsync(target.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def mkdir_root(path):
    path = Path(path)
    safe_directory(path, missing=True)
    if not path.exists():
        mkdir_root(path.parent)
        path.mkdir(mode=0o755)
        os.chown(path, 0, 0)
        os.chmod(path, 0o755)
        sync_directory(path.parent)


def validate_candidates(package, stage):
    candidates = {}
    for number, item in enumerate(package["files"]):
        candidate = stage / (str(number) + "-" + Path(item["path"]).name)
        candidate.write_bytes(item["content"])
        candidate.chmod(0o600)
        candidates[item["path"]] = candidate
        if item["path"].endswith(".py"):
            compile(item["content"], item["path"], "exec", dont_inherit=True)
        if item["path"].endswith(".sh") or item["path"] == "/usr/local/sbin/teslausb-web-sudo":
            command("bash", "-n", str(candidate))
        if item["path"] == SUDOERS:
            command("visudo", "-cf", str(candidate))
    if NGINX_SITE in candidates:
        main, _ = read_regular("/etc/nginx/nginx.conf")
        enabled = Path("/etc/nginx/sites-enabled")
        safe_directory(enabled)
        shadow = stage / "sites-enabled"
        shadow.mkdir(mode=0o700)
        found = False
        for number, entry in enumerate(sorted(enabled.iterdir())):
            # Only the established TeslaUSB sites-enabled symlink is accepted.
            target = Path(os.path.realpath(entry)) if entry.is_symlink() else entry
            if entry.is_symlink():
                require(str(target) == NGINX_SITE, "Unexpected nginx enabled-site symlink")
            if str(target) == NGINX_SITE:
                content = candidates[NGINX_SITE].read_bytes()
                found = True
            else:
                content, _ = read_regular(target)
            (shadow / ("site-" + str(number))).write_bytes(content)
        require(found, "Expected enabled TeslaUSB nginx site was not found")
        main_text, count = re.subn(r"include\s+/etc/nginx/sites-enabled/\*\s*;",
                                  "include " + str(shadow) + "/*;", main.decode("utf-8"))
        require(count == 1, "Unsupported nginx main include layout")
        config = stage / "nginx.conf"
        config.write_text(main_text, encoding="utf-8")
        command("nginx", "-t", "-c", str(config))


def write_manifest(directory, manifest):
    atomic(directory / "manifest.json", (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode(), 0o600)


def remount(mode):
    command("mount", "-o", "remount," + mode, "/")
    require(root_mode() == mode, "Could not verify root remount to " + mode)


def install(package, state, originals, units, original_mode):
    mkdir_root(BASE)
    directory = BASE / ("modern-ui-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:8])
    directory.mkdir(mode=0o700)
    sync_directory(BASE)
    manifest = {"schema_version": 1, "source_commit": package.get("source_commit"), "phase": "prepared",
                "boot": state["boot"], "root_mode": original_mode, "runtime_before": state,
                "cleanup_before": units, "created_private_directories": [], "files": []}
    for number, item in enumerate(package["files"]):
        saved = None
        if originals[item["path"]] is not None:
            saved = str(number) + ".original"
            atomic(directory / saved, originals[item["path"]], 0o600)
        manifest["files"].append({"path": item["path"], "before": item["before"],
                                  "after_sha256": item["sha256"], "backup": saved})
    write_manifest(directory, manifest)
    descriptor = os.open(PENDING, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as pending:
        pending.write((str(directory) + "\n").encode())
        pending.flush()
        os.fsync(pending.fileno())
    sync_directory(BASE)
    changed = []
    created_modern = False
    error = None
    rollback_errors = []
    has_nginx = any(item["path"] == NGINX_SITE for item in package["files"])
    has_units = any(item["path"].startswith("/etc/systemd/system/") for item in package["files"])
    try:
        # Recheck immediately before changing the root filesystem, including
        # files prepared while another process may have been updating state.
        require(runtime_state() == state, "Recording runtime changed before installation")
        for item in package["files"]:
            require(read_regular(item["path"], absent=True)[1] == item["before"], "Prior file changed before installation")
        no_root_writers()
        storage_preflight(package, originals)
        if original_mode == "ro":
            remount("rw")
        if any(Path(item["path"]).parent == MODERN for item in package["files"]) and not MODERN.exists():
            mkdir_root(MODERN)
            created_modern = True
        user, missing = private_state(package)
        for path in missing:
            Path(path).mkdir(mode=0o700)
            os.chown(path, user.pw_uid, user.pw_gid)
            sync_directory(Path(path).parent)
            manifest["created_private_directories"].append(path)
        manifest["phase"] = "applying"
        write_manifest(directory, manifest)
        # Publish the dispatcher last so every newly reachable helper exists.
        ordered = sorted(package["files"], key=lambda item: item["path"] == "/var/www/html/cgi-bin/api-v1.sh")
        for item in ordered:
            changed.append(item)
            atomic(item["path"], item["content"], DESTINATIONS[item["path"]])
        if SUDOERS in {item["path"] for item in package["files"]}:
            command("visudo", "-cf", SUDOERS)
        if has_nginx:
            command("nginx", "-t")
        if has_units:
            command("systemctl", "daemon-reload")
        if has_nginx:
            command("systemctl", "reload", "nginx.service")
        require(runtime_state() == state, "Recording service or USB attachment changed during installation")
        after_units = cleanup_state()
        for unit in (SERVICE, TIMER):
            require(after_units[unit].get("ActiveState") == units[unit].get("ActiveState"),
                    "Cleanup activation changed during installation")
        for item in package["files"]:
            expected = {"sha256": item["sha256"], "mode": DESTINATIONS[item["path"]], "uid": 0, "gid": 0}
            require(read_regular(item["path"])[1] == expected, "Installed file verification failed")
        if root_mode() != original_mode:
            no_root_writers()
            remount(original_mode)
        manifest["phase"] = "files_verified"
        write_manifest(directory, manifest)
    except BaseException as caught:
        error = caught
        manifest["phase"] = "rolling_back"
        with contextlib.suppress(Exception):
            write_manifest(directory, manifest)
        try:
            if changed and root_mode() == "ro":
                remount("rw")
        except BaseException as rollback_error:
            rollback_errors.append("Rollback remount: " + str(rollback_error))
        for item in reversed(changed):
            try:
                if item["before"] is None:
                    current, metadata = read_regular(item["path"], absent=True)
                    if metadata is not None:
                        require(digest(current) == item["sha256"], "New file changed before rollback")
                        Path(item["path"]).unlink()
                        sync_directory(Path(item["path"]).parent)
                else:
                    _current, metadata = read_regular(item["path"], absent=True)
                    if metadata != item["before"]:
                        candidate = {"sha256": item["sha256"], "mode": DESTINATIONS[item["path"]], "uid": 0, "gid": 0}
                        require(metadata == candidate, "Existing file changed independently before rollback")
                        atomic(item["path"], originals[item["path"]], item["before"]["mode"],
                               item["before"]["uid"], item["before"]["gid"])
            except BaseException as rollback_error:
                rollback_errors.append(item["path"] + ": " + str(rollback_error))
        try:
            if created_modern and MODERN.exists() and not any(MODERN.iterdir()):
                MODERN.rmdir()
                sync_directory(MODERN.parent)
            if has_units and changed and not rollback_errors:
                command("systemctl", "daemon-reload")
            if has_nginx and changed and not rollback_errors:
                command("nginx", "-t")
                command("systemctl", "reload", "nginx.service")
            require(runtime_state() == state, "Recording runtime changed; it was not modified by rollback")
            restored_units = cleanup_state()
            require(restored_units == units, "Cleanup unit state differs after rollback")
        except BaseException as rollback_error:
            rollback_errors.append(type(rollback_error).__name__ + ": " + str(rollback_error))
    finally:
        try:
            if root_mode() != original_mode:
                no_root_writers()
                remount(original_mode)
        except BaseException as mount_error:
            rollback_errors.append("Root mode restoration: " + str(mount_error))
    if error is not None or rollback_errors:
        manifest["phase"] = "recovery_required" if rollback_errors else "rolled_back"
        manifest["failure_type"] = type(error).__name__ if error is not None else "RootModeError"
        manifest["rollback_errors"] = rollback_errors
        write_manifest(directory, manifest)
        # Retain the pending guard even after clean rollback: a human must
        # inspect the transaction before another installer can overwrite it.
        raise InstallError("Update failed; " + manifest["phase"] + "; inspect private backup " + str(directory)) from error
    manifest["phase"] = "complete"
    write_manifest(directory, manifest)
    PENDING.unlink()
    sync_directory(BASE)
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--install", action="store_true")
    parser.add_argument("package_json")
    arguments = parser.parse_args()
    require(os.name == "posix" and os.geteuid() == 0, "This installer requires reviewed root execution on Linux")
    os.umask(0o077)
    def interrupted(_number, _frame):
        raise InstallError("Installation interrupted; transaction recovery is required")
    signal.signal(signal.SIGTERM, interrupted)
    # Package may be staged in sticky /tmp, but its final inode must be a
    # single-link root-owned non-writable regular file; O_NOFOLLOW pins it.
    data, _ = read_regular(arguments.package_json, check_parents=False)
    package = parse_package(data)
    state, originals, units, mode_before = validate_preconditions(package)
    with tempfile.TemporaryDirectory(prefix="teslausb-modern-check-") as temporary:
        validate_candidates(package, Path(temporary))
    if arguments.check:
        print(json.dumps({"ok": True, "mode": "check", "files": len(package["files"]),
                          "root_mode": mode_before, "source_commit": package.get("source_commit"),
                          "timer_activated": False}))
        return
    backup = install(package, state, originals, units, mode_before)
    print(json.dumps({"ok": True, "mode": "install", "backup": str(backup),
                      "root_mode": mode_before, "timer_activated": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        sys.exit(1)
