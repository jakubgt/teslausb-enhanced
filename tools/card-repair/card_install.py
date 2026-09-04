#!/usr/bin/env python3
"""Manifest-bound, rollback-capable repair of an already-configured TeslaUSB.

This module is embedded in the generated run_once. It has no command-line or
environment overrides: test filesystems/adapters can only be passed by tests.
It deliberately never opens a recording, snapshot image, or configuration file.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import types


PENDING = "/mutable/teslausb/manual-fixes/runtime-maintenance.pending"
BACKUP_PARENT = "/mutable/teslausb/manual-fixes"
DROPIN = "/etc/systemd/system/teslausb.service.d/40-card-maintenance.conf"
SERVICE = "teslausb.service"
LIVE_MOUNTS = {"/mnt/cam", "/mnt/music", "/mnt/lightshow", "/mnt/boombox"}
DROPIN_DATA = (
    "# Targeted TeslaUSB card maintenance; preserve the interruption guard.\n"
    "[Unit]\n"
    f"ConditionPathExists=!{PENDING}\n"
    "[Service]\n"
    "KillMode=control-group\n"
).encode()


class RepairError(RuntimeError):
    """Fail closed without guessing at an unexpected device state."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical_json(value):
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def load_payload(path, expected_sha256, entries):
    """Authenticate before parsing; read exact regular tar members, no extraction."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
        raise RepairError("Repair payload is missing, unsafe, or unexpectedly large")
    raw = path.read_bytes()
    if digest(raw) != expected_sha256:
        raise RepairError("Repair payload checksum does not match")
    expected = {item["member"]: item for item in entries}
    if len(expected) != len(entries):
        raise RepairError("Duplicate manifest member")
    result = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        for member in archive.getmembers():
            if (member.name not in expected or member.name in result or
                    not member.isfile() or member.linkname or member.pax_headers or
                    member.size > 1024 * 1024):
                raise RepairError("Repair payload contains an unexpected member")
            if PurePosixPath(member.name).name != member.name:
                raise RepairError("Repair payload member is not a flat filename")
            data = archive.extractfile(member).read()
            if digest(data) != expected[member.name]["sha256"]:
                raise RepairError(f"Payload member checksum mismatch: {member.name}")
            result[member.name] = data
    if set(result) != set(expected):
        raise RepairError("Repair payload has missing members")
    return result


class RootFS:
    """Fixed root-owned paths; tests explicitly instantiate a private mock root."""

    def __init__(self, root=Path("/"), check_ownership=True):
        self.root = Path(root)
        self.check_ownership = check_ownership

    def path(self, name):
        parsed = PurePosixPath(name)
        if not parsed.is_absolute() or ".." in parsed.parts:
            raise RepairError(f"Unsafe absolute path: {name}")
        return self.root.joinpath(*parsed.parts[1:])

    def owned(self, st, label):
        if self.check_ownership and (st.st_uid != 0 or st.st_gid != 0):
            raise RepairError(f"Not owned by root:root: {label}")

    def parents(self, name, allow_missing=False):
        target = self.path(name)
        for parent in reversed(target.parents):
            if parent == self.root.parent and self.root != Path("/"):
                continue
            if not parent.is_relative_to(self.root):
                continue
            try:
                st = parent.lstat()
            except FileNotFoundError:
                if allow_missing:
                    continue
                raise RepairError(f"Required parent directory is missing: {parent}")
            if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
                raise RepairError(f"Unsafe parent directory: {parent}")
            self.owned(st, str(parent))
            if self.check_ownership and stat.S_IMODE(st.st_mode) & 0o022:
                raise RepairError(f"Parent directory is writable by non-root: {parent}")

    def inspect(self, name, absent=False):
        self.parents(name)
        path = self.path(name)
        try:
            st = path.lstat()
        except FileNotFoundError:
            if absent:
                return None
            raise RepairError(f"Required installed file is missing: {name}")
        if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_nlink != 1:
            raise RepairError(f"Not a private regular file: {name}")
        self.owned(st, name)
        if self.check_ownership and stat.S_IMODE(st.st_mode) & 0o022:
            raise RepairError(f"Installed file is writable by non-root: {name}")
        data = path.read_bytes()
        return {"sha256": digest(data), "mode": stat.S_IMODE(st.st_mode),
                "uid": st.st_uid, "gid": st.st_gid, "data": data}

    def ensure_dir(self, name, mode=0o700):
        self.parents(name, allow_missing=True)
        path = self.path(name)
        if path.exists() or path.is_symlink():
            st = path.lstat()
            if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
                raise RepairError(f"Unsafe directory: {name}")
            self.owned(st, name)
            if self.check_ownership and stat.S_IMODE(st.st_mode) & 0o022:
                raise RepairError(f"Directory is writable by non-root: {name}")
            return False
        # Only create this one directory. Its validated parent must exist.
        path.mkdir(mode=mode)
        if self.check_ownership:
            os.chown(path, 0, 0)
        self.sync_dir(path.parent)
        return True

    def sync_dir(self, directory):
        if os.name != "nt":
            fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)

    def atomic(self, name, data, mode=0o600, uid=0, gid=0):
        self.parents(name)
        target = self.path(name)
        # An untrusted link must not be silently replaced, even though replace
        # would not follow it. All mutations are revalidated immediately.
        self.inspect(name, absent=True)
        fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.maintenance.", dir=target.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                if self.check_ownership:
                    os.fchown(stream.fileno(), uid, gid)
                os.chmod(temporary, mode)
                os.fsync(stream.fileno())
            os.replace(temporary, target)
            self.sync_dir(target.parent)
            installed = self.inspect(name)
            if installed["sha256"] != digest(data):
                raise RepairError(f"Installed file verification failed: {name}")
            if self.check_ownership and (installed["mode"], installed["uid"], installed["gid"]) != (mode, uid, gid):
                raise RepairError(f"Installed file metadata mismatch: {name}")
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def remove_regular(self, name, allowed_hashes):
        current = self.inspect(name, absent=True)
        if current is None:
            return
        if current["sha256"] not in allowed_hashes:
            raise RepairError(f"Refusing to remove an unknown file: {name}")
        path = self.path(name)
        path.unlink()
        self.sync_dir(path.parent)


class FileTransaction:
    def __init__(self, fs, config, contents):
        self.fs = fs
        self.config = config
        self.contents = contents
        self.entries = [item for item in config["entries"] if "destination" in item]
        self.by_destination = {item["destination"]: item for item in self.entries}
        if len(self.by_destination) != len(self.entries) or DROPIN not in self.by_destination:
            raise RepairError("Invalid installation destination manifest")

    def preflight(self):
        for name, expected_sha in self.config.get("prerequisites", {}).items():
            if self.fs.inspect(name)["sha256"] != expected_sha:
                raise RepairError(f"Earlier required repair is missing or customized: {name}")
        records = []
        for item in self.entries:
            # Only our newly created service drop-in may have a missing parent.
            parent = str(PurePosixPath(item["destination"]).parent)
            if item["destination"] == DROPIN and not self.fs.path(parent).exists():
                self.fs.parents(parent)
                current = None
            else:
                current = self.fs.inspect(item["destination"], absent=item["allow_absent"])
            if current is not None and current["sha256"] not in item["allowed_sha256"]:
                raise RepairError(f"Unknown customized checksum; not overwriting {item['destination']}")
            record = {"destination": item["destination"], "original": None}
            if current is not None:
                record["original"] = {key: value for key, value in current.items() if key != "data"}
            records.append(record)
        return records

    def prepare(self, records, backup):
        state = {"version": 1, "install_id": self.config["install_id"], "backup": backup,
                 "phase": "prepared", "files": [], "ssh": None}
        for index, record in enumerate(records):
            item = self.by_destination[record["destination"]]
            current = self.fs.inspect(record["destination"], absent=True) if self.fs.path(str(PurePosixPath(record["destination"]).parent)).exists() else None
            original = record["original"]
            if (None if current is None else current["sha256"]) != (None if original is None else original["sha256"]):
                raise RepairError(f"File changed after preflight: {record['destination']}")
            saved = dict(record, backup_member=f"original-{index:02d}")
            if original is not None:
                self.fs.atomic(backup + "/" + saved["backup_member"], current["data"], 0o600)
            state["files"].append(saved)
        return state

    def validate_journal(self, state):
        if (not isinstance(state, dict) or state.get("version") != 1 or
                state.get("install_id") != self.config["install_id"] or
                state.get("phase") not in {"prepared", "installing", "installed"}):
            raise RepairError("Unknown interrupted-maintenance journal")
        backup = state.get("backup", "")
        if (not isinstance(backup, str) or not backup.startswith(BACKUP_PARENT + "/runtime-maintenance.") or
                PurePosixPath(backup).parent != PurePosixPath(BACKUP_PARENT)):
            raise RepairError("Unsafe interrupted-maintenance backup path")
        self.fs.parents(backup + "/record")
        records = state.get("files")
        if not isinstance(records, list) or len(records) != len(self.entries):
            raise RepairError("Incomplete interrupted-maintenance journal")
        for index, (record, item) in enumerate(zip(records, self.entries)):
            if record.get("destination") != item["destination"] or record.get("backup_member") != f"original-{index:02d}":
                raise RepairError("Unexpected interrupted-maintenance destination")
            original = record.get("original")
            if original is None:
                if not item["allow_absent"]:
                    raise RepairError("Required original missing from journal")
                continue
            if (set(original) != {"sha256", "mode", "uid", "gid"} or
                    original["sha256"] not in item["allowed_sha256"] or
                    (self.fs.check_ownership and (original["uid"], original["gid"]) != (0, 0)) or
                    not isinstance(original["mode"], int) or not 0 <= original["mode"] <= 0o777 or
                    (self.fs.check_ownership and original["mode"] & 0o022)):
                raise RepairError("Invalid original metadata in maintenance journal")
            backup_file = self.fs.inspect(backup + "/" + record["backup_member"])
            if backup_file["sha256"] != original["sha256"]:
                raise RepairError("Interrupted-maintenance backup checksum mismatch")

    def persist(self, state):
        self.fs.atomic(PENDING, canonical_json(state))

    def clear_pending(self, state):
        pending = self.fs.inspect(PENDING, absent=True)
        if pending is None:
            return
        saved = json.loads(pending["data"])
        self.validate_journal(saved)
        # The on-disk phase may lag if persisting a new phase failed. Every
        # other field must still identify precisely this backed-up transaction.
        if {key: value for key, value in saved.items() if key != "phase"} != {
                key: value for key, value in state.items() if key != "phase"}:
            raise RepairError("Pending journal changed unexpectedly")
        self.fs.remove_regular(PENDING, {pending["sha256"]})

    def install(self, state, after_write=None):
        # fsync the condition before touching scripts. An interrupted next boot
        # therefore cannot start a mixed old/new runtime through this service.
        state["phase"] = "installing"
        self.persist(state)
        order = [self.by_destination[DROPIN]] + [item for item in self.entries if item["destination"] != DROPIN]
        originals = {record["destination"]: record["original"] for record in state["files"]}
        for index, item in enumerate(order):
            current = self.fs.inspect(item["destination"], absent=True)
            original = originals[item["destination"]]
            if (None if current is None else current["sha256"]) != (None if original is None else original["sha256"]):
                raise RepairError(f"File changed after backup: {item['destination']}")
            self.fs.atomic(item["destination"], self.contents[item["member"]], item["mode"])
            if after_write:
                after_write(index)

    def verify_final(self):
        for item in self.entries:
            current = self.fs.inspect(item["destination"])
            if current["sha256"] != item["sha256"]:
                raise RepairError(f"Final checksum mismatch: {item['destination']}")

    def rollback(self, state):
        self.validate_journal(state)
        # Validate all destinations first; do not partially rollback over a new
        # customization. Preserve the maintenance condition if anything is odd.
        for record in state["files"]:
            item = self.by_destination[record["destination"]]
            current = self.fs.inspect(record["destination"], absent=True)
            allowed = {item["sha256"]}
            if record["original"] is not None:
                allowed.add(record["original"]["sha256"])
            if current is not None and current["sha256"] not in allowed:
                raise RepairError(f"Unknown modified file blocks rollback: {record['destination']}")
        order = [record for record in reversed(state["files"]) if record["destination"] != DROPIN]
        order += [record for record in state["files"] if record["destination"] == DROPIN]
        for record in order:
            item = self.by_destination[record["destination"]]
            original = record["original"]
            if original is None:
                self.fs.remove_regular(record["destination"], {item["sha256"]})
            else:
                data = self.fs.inspect(state["backup"] + "/" + record["backup_member"])["data"]
                self.fs.atomic(record["destination"], data, original["mode"], original["uid"], original["gid"])
        self.clear_pending(state)


class LinuxSystem:
    def __init__(self, fs):
        self.fs = fs
        self.locks = []
        self.runtime_masked = False

    @staticmethod
    def command(args, timeout=45, okay=(0,), data=None):
        result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout, check=False)
        if result.returncode not in okay:
            # Avoid logging config or secret-bearing command output.
            raise RepairError(f"Command failed ({result.returncode}): {' '.join(args[:3])}")
        return result.stdout.decode("utf-8", "strict").strip()

    def mount_info(self, path):
        text = self.command(["findmnt", "-nr", "-T", path, "-o", "TARGET,OPTIONS"])
        fields = text.split()
        if len(fields) != 2:
            raise RepairError(f"Unable to identify filesystem for {path}")
        options = set(fields[1].split(","))
        if len(options & {"ro", "rw"}) != 1:
            raise RepairError(f"Ambiguous mount mode for {path}")
        return fields[0], "rw" in options

    def acquire_installer_lock(self):
        import fcntl
        lock_path = "/run/teslausb-card-maintenance.lock"
        self.fs.inspect(lock_path, absent=True)
        fd = os.open(self.fs.path(lock_path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        self.locks.append(fd)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
                (info.st_uid, info.st_gid) != (0, 0) or info.st_mode & 0o022):
            raise RepairError("Unsafe maintenance-operation lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RepairError("Another maintenance hook is already running") from exc

    def remount(self, target, writable):
        mode = "rw" if writable else "ro"
        self.command(["mount", "-o", f"remount,{mode}", target])
        actual_target, actual_rw = self.mount_info(target)
        if actual_target != target or actual_rw != writable:
            raise RepairError(f"Could not verify {target} remounted {mode}")

    def preflight(self, boot):
        if os.geteuid() != 0:
            raise RepairError("The maintenance hook must run as root")
        if self.mount_info("/mutable") != ("/mutable", True):
            raise RepairError("/mutable must be its own writable filesystem")
        if self.mount_info("/backingfiles")[0] != "/backingfiles":
            raise RepairError("/backingfiles must be mounted before maintenance")
        root_mount = self.mount_info("/")
        boot_mount = self.mount_info(str(boot))
        if root_mount[0] != "/" or boot_mount[0] not in {"/boot", "/boot/firmware"}:
            raise RepairError("Unexpected root or boot mount layout")
        # Refuse to modify a card attached to a configured USB host. The hook
        # must be booted on PWR IN only, after recording has stopped.
        self.ensure_no_data_host()
        if self.command(["systemctl", "show", "-p", "LoadState", "--value", SERVICE]) != "loaded":
            raise RepairError("TeslaUSB service is missing or already masked")
        return root_mount, boot_mount

    @staticmethod
    def ensure_no_data_host():
        for path in Path("/sys/class/udc").glob("*/state"):
            state_value = path.read_text().strip()
            if state_value not in {"not attached", "powered"}:
                raise RepairError("USB data host is attached; boot on PWR IN only")

    @staticmethod
    def filesystem_workers():
        workers = []
        for comm in Path("/proc").glob("[0-9]*/comm"):
            try:
                name = comm.read_text().strip()
            except (FileNotFoundError, ProcessLookupError):
                continue
            if name == "fstrim" or name == "e2fsck" or name == "resize2fs" or name == "fsck" or name.startswith("fsck."):
                workers.append(name)
        return workers

    def live_mounts(self):
        text = self.command(["findmnt", "--kernel", "--list", "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS"])
        rows = json.loads(text).get("filesystems")
        if not isinstance(rows, list) or not rows:
            raise RepairError("Could not inspect live USB mounts")
        live = {}
        for row in rows:
            target = row.get("target", "")
            if any(target.startswith(parent + "/") for parent in LIVE_MOUNTS):
                raise RepairError("Unexpected nested live USB image mount")
            if target in LIVE_MOUNTS:
                if target in live:
                    raise RepairError("Duplicate live USB image mount")
                live[target] = row
        return live

    def startup_gadget_ready(self):
        active = self.command(["systemctl", "show", "-p", "ActiveState", "--value", SERVICE])
        if active in {"inactive", "failed"}:
            # A condition-skipped interrupted transaction must be recoverable
            # without waiting for the intentionally blocked runtime to start.
            return True
        if active != "active":
            return False
        gadget = Path("/sys/kernel/config/usb_gadget/teslausb")
        try:
            if not (gadget / "UDC").read_text().strip():
                return False
            return any(path.read_text().strip() == "/backingfiles/cam_disk.bin"
                       for path in gadget.glob("configs/*/mass_storage.0/lun.*/file"))
        except FileNotFoundError:
            return False

    def wait_for_startup(self, log):
        # Startup may still be checking/trimming an image when rc.local reaches
        # this hook. Do not kill a filesystem tool just to make installation
        # faster. Two consecutive clear checks reduce the normal startup race.
        deadline = time.monotonic() + 600
        clear_checks = 0
        announced = False
        while True:
            self.ensure_no_data_host()
            active = self.filesystem_workers()
            mounted_rw = any("rw" in row.get("options", "").split(",") for row in self.live_mounts().values())
            if not active and not mounted_rw and self.startup_gadget_ready():
                clear_checks += 1
                if clear_checks == 2:
                    return
            else:
                clear_checks = 0
                if not announced:
                    log("Waiting up to 10 minutes for startup filesystem work to finish and the camera gadget to be prepared safely")
                    announced = True
            if time.monotonic() >= deadline:
                raise RepairError("Startup filesystem work is still busy; no runtime files replaced. Leave on PWR IN and retry after a clean reboot")
            time.sleep(2)

    def quiesce(self):
        self.command(["systemctl", "mask", "--runtime", SERVICE])
        self.runtime_masked = True
        self.command(["systemctl", "stop", SERVICE], timeout=75)
        state_value = self.command(["systemctl", "show", "-p", "ActiveState", "--value", SERVICE])
        if state_value not in {"inactive", "failed"}:
            raise RepairError("TeslaUSB service did not stop")
        # Control-group emptiness is independently checked. Old KillMode=mixed
        # units must not leave descendants able to run partially updated files.
        group = self.command(["systemctl", "show", "-p", "ControlGroup", "--value", SERVICE])
        if group:
            candidate = Path("/sys/fs/cgroup") / group.lstrip("/")
            for processes in candidate.glob("**/cgroup.procs"):
                if processes.read_text().strip():
                    raise RepairError("TeslaUSB worker remains after service stop")

    def lock_workers(self):
        import fcntl
        self.fs.parents("/backingfiles/snapshots/lock-check")
        snapshots = self.fs.path("/backingfiles/snapshots")
        fd = os.open(snapshots, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.locks.append(fd)
        self.acquire(fd, fcntl)
        self.fs.ensure_dir("/run/teslausb", 0o700)
        lock_path = "/run/teslausb/gadget-operation.lock"
        self.fs.inspect(lock_path, absent=True)
        fd = os.open(self.fs.path(lock_path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        self.locks.append(fd)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or (st.st_uid, st.st_gid) != (0, 0):
            raise RepairError("Unsafe gadget-operation lock")
        self.acquire(fd, fcntl)
        if self.filesystem_workers():
            raise RepairError("A filesystem worker remains after service stop; refusing to proceed")
        self.clean_residual_live_mounts()

    def clean_residual_live_mounts(self):
        # Only an ordinary unmount of a positively identified local image is
        # permitted. Never fsck, force/lazy-unmount, detach a loop, or touch the
        # contents. Any busy/unknown state leaves the hook pending for a retry.
        self.ensure_no_data_host()
        live = self.live_mounts()
        for target, row in live.items():
            source = row.get("source", "")
            match = re.fullmatch(r"(/dev/loop[0-9]+)(?:p[0-9]+)?", source)
            if not match or row.get("fstype") not in {"vfat", "exfat"}:
                raise RepairError("Unknown live USB image mount; no unmount attempted")
            backing = self.command(["losetup", "--list", "--noheadings", "--output", "BACK-FILE", match.group(1)])
            drive = PurePosixPath(target).name
            if backing != f"/backingfiles/{drive}_disk.bin":
                raise RepairError("Live USB loop backing file does not match its expected image")
        for target in live:
            self.command(["umount", "--", target], timeout=30)
        if self.live_mounts():
            raise RepairError("A live USB image remains mounted; refusing to proceed")

    @staticmethod
    def acquire(fd, fcntl):
        deadline = time.monotonic() + 30
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RepairError("A snapshot or gadget worker is busy; no files replaced")
                time.sleep(0.2)

    def release(self):
        while self.locks:
            os.close(self.locks.pop())


def load_ssh_module(contents):
    module = types.ModuleType("teslausb_card_ssh_key_setup")
    sys.modules[module.__name__] = module
    exec(compile(contents["ssh_key_setup.py"], "ssh_key_setup.py", "exec"), module.__dict__)
    return module


def run(config):
    fs = RootFS()
    system = LinuxSystem(fs)
    # /teslausb is the setup-created boot alias. Resolve this one alias, then
    # prohibit symlinks in every individual payload/trigger/log path.
    boot_alias = Path("/teslausb")
    boot = boot_alias.resolve(strict=True)
    if boot not in {Path("/boot"), Path("/boot/firmware")}:
        raise RepairError("Unexpected /teslausb boot alias")
    payload = boot / config["payload_name"]
    contents = load_payload(payload, config["payload_sha256"], config["entries"])
    transaction = FileTransaction(fs, config, contents)
    ssh = load_ssh_module(contents) if "ssh_key_setup.py" in contents else None
    root_info, boot_info = system.preflight(boot)
    for item in config["entries"]:
        data = contents[item["member"]]
        if item.get("syntax") == "bash":
            system.command(["bash", "-n"], data=data)
        elif item.get("syntax") == "python":
            compile(data, item["member"], "exec")
    trigger = boot / "run_once"
    for path in (trigger, boot / config["marker_name"], boot / config["log_name"]):
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise RepairError(f"Unsafe boot control file: {path.name}")
    if not trigger.is_file():
        raise RepairError("Original run_once trigger is missing")
    trigger_hash = digest(trigger.read_bytes())
    system.acquire_installer_lock()
    fs.parents(BACKUP_PARENT)
    fs.ensure_dir(BACKUP_PARENT)
    pending = fs.inspect(PENDING, absent=True)
    interrupted = None
    if pending:
        interrupted = json.loads(pending["data"])
        transaction.validate_journal(interrupted)
    else:
        transaction.preflight()
    changed_mounts = False
    state = None
    completed = False
    log_lines = []
    status = 1

    def log(message):
        line = time.strftime("%Y-%m-%dT%H:%M:%S%z") + " : " + message
        print(line, flush=True)
        log_lines.append(line)

    with tempfile.TemporaryDirectory(prefix="teslausb-card-maintenance.") as work:
        try:
            log("Authenticated targeted runtime maintenance " + config["install_id"])
            system.wait_for_startup(log)
            system.quiesce()
            system.lock_workers()
            changed_mounts = True
            if not root_info[1]:
                system.remount("/", True)
            if not boot_info[1]:
                system.remount(boot_info[0], True)
            if interrupted:
                log("Recovering an interrupted maintenance transaction before retrying")
                if interrupted.get("ssh") is not None:
                    if ssh is None:
                        raise RepairError("SSH recovery helper is absent")
                    ssh.rollback(interrupted["ssh"])
                transaction.rollback(interrupted)
                system.command(["systemctl", "daemon-reload"])
            records = transaction.preflight()
            fs.ensure_dir(str(PurePosixPath(DROPIN).parent), 0o755)
            backup_path = tempfile.mkdtemp(prefix="runtime-maintenance.", dir=fs.path(BACKUP_PARENT))
            os.chmod(backup_path, 0o700)
            fs.sync_dir(Path(backup_path).parent)
            backup = str(Path(backup_path))
            state = transaction.prepare(records, backup)
            if ssh:
                public_key = Path(backup) / "authenticated-public-key.pub"
                fs.atomic(str(public_key), contents["ssh-public-key.pub"], 0o600)
                ssh_backup = Path(backup) / "ssh"
                ssh_backup.mkdir(mode=0o700)
                state["ssh"] = ssh.prepare(str(public_key), str(ssh_backup),
                                            client_address=config.get("ssh_client_address"))
            transaction.persist(state)
            transaction.install(state)
            system.command(["systemctl", "daemon-reload"])
            if ssh:
                ssh.apply(state["ssh"])
            transaction.verify_final()
            state["phase"] = "installed"
            transaction.persist(state)
            # This root-owned journal is retained alongside originals even
            # after the pending guard is removed at commit.
            fs.atomic(backup + "/completed.json", canonical_json(state))
            marker_data = canonical_json({"install_id": config["install_id"],
                "source_commit": config["source_commit"], "payload_sha256": config["payload_sha256"],
                "backup": backup, "ssh_key_installed": ssh is not None,
                "recordings_modified": False, "next_step": "Reboot on PWR IN before returning to the car"})
            # Boot is FAT; ownership/modes do not have Unix persistence there.
            os.sync()
            transaction.clear_pending(state)
            completed = True
            # A post-commit marker failure must not roll back the coherent
            # installed runtime; the unchanged hook can retry idempotently.
            boot_atomic(boot / config["marker_name"], marker_data)
            # Recheck the original hook, then consume only after a complete
            # durable install. Unique retries never overwrite previous hooks.
            if trigger.is_symlink() or digest(trigger.read_bytes()) != trigger_hash:
                raise RepairError("Maintenance succeeded but run_once changed; trigger not consumed")
            archived = boot / ("ran_once.runtime-maintenance." + config["install_id"])
            if archived.exists() or archived.is_symlink():
                archived = boot / (archived.name + ".retry." + os.urandom(6).hex())
            os.rename(trigger, archived)
            fs.sync_dir(boot)
            log("Maintenance applied and verified. Originals backed up at " + backup)
            log("TeslaUSB recording service is deliberately stopped until a clean reboot; use PWR IN only for that reboot.")
            status = 0
        except Exception as exc:
            log("STOP: " + str(exc))
            if state is not None and not completed:
                try:
                    if state.get("ssh") is not None:
                        ssh.rollback(state["ssh"])
                    transaction.rollback(state)
                    system.command(["systemctl", "daemon-reload"])
                    log("All installed files and SSH changes rolled back to verified originals")
                except Exception as rollback_exc:
                    log("ROLLBACK NEEDS ATTENTION: " + str(rollback_exc))
                    log("Do not use in the car; keep the pending hook and payload for safe recovery")
            raise
        finally:
            system.release()
            if changed_mounts:
                try:
                    log_path = boot / config["log_name"]
                    if log_path.is_symlink() or (log_path.exists() and not log_path.is_file()):
                        raise RepairError("Unsafe boot log path")
                    previous = log_path.read_bytes() if log_path.exists() else b""
                    boot_atomic(log_path, previous + ("\n".join(log_lines) + "\n").encode())
                except Exception as log_exc:
                    print("Could not persist boot log: " + str(log_exc), file=sys.stderr, flush=True)
                os.sync()
                # A runtime mask intentionally remains until reboot. Never
                # start recording inside the maintenance hook or while locks
                # are held. No persistent service enablement changes are made.
                restoration_errors = []
                for target, was_rw in (boot_info, root_info):
                    if not was_rw:
                        try:
                            system.remount(target, False)
                        except Exception as exc:
                            restoration_errors.append(str(exc))
                if restoration_errors:
                    raise RepairError("Could not restore read-only mounts: " + "; ".join(restoration_errors))
    return status


def boot_atomic(path, data):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise RepairError("Unsafe boot output path: " + path.name)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        if path.read_bytes() != data:
            raise RepairError("Boot output verification failed: " + path.name)
        RootFS().sync_dir(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def persist_failure_log(config, message):
    """Make preflight failures visible on FAT without changing runtime files."""
    boot = Path("/teslausb").resolve(strict=True)
    if boot not in {Path("/boot"), Path("/boot/firmware")}:
        raise RepairError("Cannot save failure log: unexpected boot alias")
    system = LinuxSystem(RootFS())
    target, was_rw = system.mount_info(str(boot))
    if target != str(boot):
        raise RepairError("Cannot save failure log: unexpected boot filesystem")
    log_path = boot / config["log_name"]
    if log_path.is_symlink() or (log_path.exists() and not log_path.is_file()):
        raise RepairError("Cannot save failure log: unsafe log file")
    try:
        if not was_rw:
            system.remount(target, True)
        previous = log_path.read_bytes()[-2 * 1024 * 1024:] if log_path.exists() else b""
        line = time.strftime("%Y-%m-%dT%H:%M:%S%z") + " : STOP: " + message + "\n"
        boot_atomic(log_path, previous + line.encode())
        os.sync()
    finally:
        if not was_rw:
            system.remount(target, False)
