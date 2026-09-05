#!/usr/bin/python3
"""Serialize offline FAT checks; give small Pis temporary RAM-only swap.

Callers must also hold the snapshot/gadget locks and disconnect any host that
can write the image. Nothing here changes boot configuration or disk swap.
"""

import argparse
import contextlib
import errno
import os
import pathlib
import re
import signal
import stat
import subprocess
import time


RUNTIME = pathlib.Path("/run/teslausb-fsck")
MIB = 1024 * 1024
FAILURE = 69


class CheckError(Exception):
    pass


def log(message):
    print("filesystem-check: " + message, flush=True)


def command(args, timeout=30, capture=True):
    try:
        return subprocess.run(args, check=False, timeout=timeout, text=True,
                              stdout=subprocess.PIPE if capture else None,
                              stderr=subprocess.STDOUT if capture else None)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CheckError("command failed: " + str(args[0]) + ": " + str(exc)) from exc


def require_command(args):
    result = command(args)
    if result.returncode != 0:
        raise CheckError(f"{args[0]} exited {result.returncode}: {result.stdout or ''}")
    return result.stdout.strip()


def block_identity(path):
    info = pathlib.Path(path).lstat()
    if not stat.S_ISBLK(info.st_mode) or info.st_uid != 0:
        raise CheckError("device must be a root-owned block device, not a symlink")
    return os.major(info.st_rdev), os.minor(info.st_rdev)


def backing_identity(directory):
    name = (directory / "loop/backing_file").read_text().strip()
    name = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), name)
    if not name.startswith("/"):
        raise CheckError("loop backing file is not an absolute path")
    info = os.stat(name)
    if not stat.S_ISREG(info.st_mode):
        raise CheckError("loop must refer to a regular image file")
    return info.st_dev, info.st_ino


def related_loop_devices(target):
    """Find every loop/partition that maps the same underlying image inode."""
    parent = re.sub(r"p[0-9]+$", "", pathlib.Path(target).name)
    wanted = backing_identity(pathlib.Path("/sys/block") / parent)
    devices = set()
    for directory in pathlib.Path("/sys/block").glob("loop[0-9]*"):
        if not re.fullmatch(r"loop[0-9]+", directory.name):
            continue
        try:
            identity = backing_identity(directory)
        except FileNotFoundError:
            # Unconfigured loop devices have no loop/backing_file attribute.
            if not (directory / "loop/backing_file").exists():
                continue
            raise CheckError("a loop has an unresolved backing file")
        if identity != wanted:
            continue
        for device in [directory, *directory.glob(directory.name + "p[0-9]*")]:
            number = (device / "dev").read_text().strip()
            if not re.fullmatch(r"[0-9]+:[0-9]+", number):
                raise CheckError("invalid loop device number in sysfs")
            devices.add(number)
    if not devices:
        raise CheckError("cannot resolve loop image aliases")
    return devices


def validate_target(path, identity=None):
    if not re.fullmatch(r"/dev/loop[0-9]+p[1-9][0-9]*", path):
        raise CheckError("only an explicit /dev/loopNpN partition is accepted")
    if pathlib.Path("/dev").resolve(strict=True) != pathlib.Path("/dev"):
        raise CheckError("/dev must not be redirected")
    current = block_identity(path)
    if identity is not None and current != identity:
        raise CheckError("target device changed during the check")
    wanted = f"{current[0]}:{current[1]}"
    related = related_loop_devices(path)
    if wanted not in related:
        raise CheckError("device path does not match a kernel loop partition")
    mounts = pathlib.Path("/proc/self/mountinfo").read_text().splitlines()
    if not mounts:
        raise CheckError("empty mount table; refusing filesystem check")
    for line in mounts:
        fields = line.split()
        if len(fields) < 10 or "-" not in fields:
            raise CheckError("cannot safely parse the mount table")
        if fields[2] in related:
            raise CheckError("target image or a loop alias is mounted; refusing filesystem check")
    return current


@contextlib.contextmanager
def exclusive_check():
    import fcntl  # Linux-only; kept local so mocked unit tests run elsewhere.
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    info = RUNTIME.lstat()
    if (RUNTIME.resolve(strict=True) != RUNTIME.absolute()
            or not stat.S_ISDIR(info.st_mode) or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise CheckError("unsafe filesystem-check lock directory")
    descriptor = os.open(RUNTIME / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
                         | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600):
            raise CheckError("unsafe filesystem-check lock file")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def memory_total():
    text = pathlib.Path("/proc/meminfo").read_text()
    match = re.search(r"^MemTotal:\s+([0-9]+) kB$", text, re.MULTILINE)
    if not match or int(match[1]) < 1024:
        raise CheckError("cannot determine total memory safely")
    return int(match[1]) * 1024


def wait_for_device(device):
    deadline = time.monotonic() + 5
    while True:
        try:
            return block_identity(device)
        except FileNotFoundError:
            if time.monotonic() >= deadline:
                raise CheckError("new zram device did not appear: " + device) from None
            time.sleep(0.05)


class TemporaryZram:
    """Only manipulate the device returned by this invocation's hot_add."""

    def __init__(self):
        self.device = None
        self.identity = None
        self.directory = None

    def active(self):
        lines = pathlib.Path("/proc/swaps").read_text().splitlines()
        if not lines or not lines[0].startswith("Filename"):
            raise CheckError("cannot inspect active swap safely")
        for line in lines[1:]:
            fields = line.split()
            if len(fields) != 5:
                raise CheckError("cannot parse active swap safely")
            if fields[0] == self.device:
                return True
            # Also recognize a device activated through another path/alias.
            name = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), fields[0])
            info = os.stat(name)
            if stat.S_ISBLK(info.st_mode):
                if (os.major(info.st_rdev), os.minor(info.st_rdev)) == self.identity:
                    return True
        return False

    def prepare(self, total):
        require_command(["/sbin/modprobe", "zram", "num_devices=0"])
        number = pathlib.Path("/sys/class/zram-control/hot_add").read_text().strip()
        if not re.fullmatch(r"[0-9]{1,7}", number):
            raise CheckError("invalid zram hot_add response")
        device = "/dev/zram" + number
        directory = pathlib.Path("/sys/block/zram" + number)
        identity = wait_for_device(device)
        if (directory.joinpath("initstate").read_text().strip() != "0"
                or directory.joinpath("disksize").read_text().strip() != "0"):
            raise CheckError("new zram device is already initialized; leaving it untouched")
        backing = directory / "backing_dev"
        if backing.exists() and backing.read_text().strip() != "none":
            raise CheckError("new zram has a disk backing device; refusing it")
        self.device, self.directory, self.identity = device, directory, identity
        if self.active():
            # An external administrator may have taken the newly allocated
            # device. It is no longer ours to initialize or deactivate.
            self.device = None
            raise CheckError("new zram device is unexpectedly active")
        size = min(512 * MIB, 2 * total) // 4096 * 4096
        limit = min(128 * MIB, total // 4) // 4096 * 4096
        (directory / "mem_limit").write_text(str(limit))
        (directory / "disksize").write_text(str(size))
        if block_identity(device) != identity:
            raise CheckError("zram device changed during setup")
        require_command(["/sbin/mkswap", device])
        require_command(["/sbin/swapon", "--priority", "100", device])
        if not self.active():
            raise CheckError("temporary zram did not become active")
        log(f"temporary RAM-only swap {device}: {size // MIB} MiB virtual, "
            f"{limit // MIB} MiB physical limit")

    def cleanup(self):
        if self.device is None:
            return
        if block_identity(self.device) != self.identity:
            raise CheckError("zram identity changed; refusing cleanup")
        if self.active():
            require_command(["/sbin/swapoff", self.device])
            if self.active():
                raise CheckError("temporary zram remains active; refusing reset")
        # A failed/timed-out swapoff raises above: never reset active swap.
        # udev/udisks may briefly hold the new device open. Retry only EBUSY,
        # sharing one deadline; every attempt rechecks ownership and inactivity.
        deadline = time.monotonic() + 10
        self.inactive_write(self.directory / "reset", "1", deadline)
        self.inactive_write(pathlib.Path("/sys/class/zram-control/hot_remove"),
                            self.device.removeprefix("/dev/zram"), deadline)
        log("temporary RAM-only swap removed")
        self.device = None

    def inactive_write(self, path, value, deadline):
        while True:
            if block_identity(self.device) != self.identity:
                raise CheckError("zram identity changed; refusing cleanup retry")
            if self.active():
                raise CheckError("zram became active; refusing cleanup retry")
            try:
                path.write_text(value)
                return
            except OSError as exc:
                if exc.errno != errno.EBUSY:
                    raise
                if time.monotonic() >= deadline:
                    raise CheckError("temporary zram cleanup remained busy at "
                                     + path.name + "; manual check required") from exc
                time.sleep(0.1)


def perform_check(target, read_only=False, interrupted=lambda: False):
    identity = validate_target(target)
    kind = require_command(["/sbin/blkid", "-p", "-s", "TYPE", "-o", "value", target])
    binaries = {"vfat": "/sbin/fsck.vfat", "exfat": "/sbin/fsck.exfat"}
    if kind not in binaries:
        raise CheckError("unsupported filesystem: " + kind)
    helper = binaries[kind]

    def check(mode):
        if interrupted():
            raise CheckError("termination requested; no further filesystem operations")
        validate_target(target, identity)
        # No helper-imposed timeout. External signals/power loss can still
        # interrupt writes; wait for the child before cleanup and fail closed.
        result = command([helper, mode, target], timeout=None, capture=False)
        log(f"{kind} {mode} returned {result.returncode}")
        return result.returncode

    status = check("-n")
    if status == 0:
        return
    repairable = {"vfat": 1, "exfat": 4}[kind]
    if read_only or status != repairable:
        raise CheckError(f"read-only check failed with status {status}; no repair attempted")
    status = check("-p")
    if status not in (0, 1):
        raise CheckError(f"repair failed with status {status}")
    # fsck.fat status 1 can also indicate an internal error, so verify afresh.
    if check("-n") != 0:
        raise CheckError("filesystem is not verified clean after repair")


def run(target, read_only=False, interrupted=lambda: False):
    if os.geteuid() != 0:
        raise CheckError("root is required")
    with exclusive_check():
        validate_target(target)
        total = memory_total()
        swap = TemporaryZram()
        try:
            if total <= 1024 * MIB:
                swap.prepare(total)  # Mandatory on small Pi; fail before fsck.
            perform_check(target, read_only, interrupted)
        finally:
            swap.cleanup()
    if interrupted():
        raise CheckError("termination requested")
    log("filesystem verified clean")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--read-only", action="store_true")
    parser.add_argument("target")
    args = parser.parse_args(argv)
    stopping = []
    previous = {}
    try:
        for name in (signal.SIGTERM, signal.SIGINT):
            previous[name] = signal.signal(name, lambda signum, frame: stopping.append(signum))
        run(args.target, args.read_only, lambda: bool(stopping))
        return 0
    except (CheckError, OSError, ValueError) as exc:
        log("STOP: " + str(exc))
        return FAILURE
    finally:
        for name, handler in previous.items():
            signal.signal(name, handler)


if __name__ == "__main__":
    raise SystemExit(main())
