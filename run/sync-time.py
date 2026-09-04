#!/usr/bin/python3
"""Keep the Pi clock usable even when no archive destination is configured.

Run as one background child of archiveloop. All network and service commands
have deadlines; retries use monotonic time and never hold a gadget/snapshot
lock. A saved time is only a lower-bound fallback, never proof of NTP sync.
"""

import contextlib
import datetime
import json
import math
import os
import pathlib
import re
import signal
import stat
import subprocess
import tempfile
import time


RUNTIME_DIR = pathlib.Path("/run/teslausb-time")
PERSIST_DIR = pathlib.Path("/mutable/teslausb-time")
# Retain the existing TeslaUSB time sources; no additional external service.
SERVERS = ("time.google.com", "129.6.15.28")
TIME_UNITS = ("ntpsec.service", "ntp.service", "systemd-timesyncd.service",
              "chrony.service", "chronyd.service")
MIN_EPOCH = 1577836800  # 2020-01-01
MAX_EPOCH = 4102444800  # 2100-01-01
RECHECK_SECONDS = 3600


def plausible_epoch(value):
    return (type(value) in (int, float) and math.isfinite(value)
            and MIN_EPOCH <= value < MAX_EPOCH)


def utc(epoch):
    return datetime.datetime.fromtimestamp(
        epoch, datetime.timezone.utc).isoformat(timespec="seconds")


def private_directory(directory):
    """Refuse redirected or non-private state, including symlink ancestors."""
    directory = pathlib.Path(directory)
    if directory == PERSIST_DIR and not os.path.ismount(directory.parent):
        raise OSError("mutable filesystem is not mounted")
    directory.mkdir(mode=0o700, exist_ok=True)
    if directory.resolve(strict=True) != directory.absolute():
        raise OSError("clock state directory resolves through a symlink")
    info = directory.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise OSError("clock state directory must be owned by root with mode 0700")


def read_state(directory, name):
    # The directory is root-only. O_NOFOLLOW and the regular-file/size check
    # also reject an accidentally replaced file, FIFO, or oversized record.
    private_directory(directory)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(directory / name, flags), "r", encoding="utf-8") as handle:
        info = os.fstat(handle.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_nlink != 1 or info.st_size > 4096
                or stat.S_IMODE(info.st_mode) & 0o077):
            raise OSError("unsafe clock state file")
        return json.load(handle)


def write_state(directory, name, document, durable=False):
    private_directory(directory)
    fd, temporary = tempfile.mkstemp(prefix=".time-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(document, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            if durable:
                os.fsync(handle.fileno())
        # Replace the directory entry; never open/follow an existing target.
        os.replace(temporary, directory / name)
        if durable:
            dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def command(args, timeout=5):
    try:
        return subprocess.run(args, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=timeout, check=False,
                              env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.TimeoutExpired):
        return None


def valid_ntp_reply(result, adjusted=False):
    if result is None or result.returncode != 0:
        return None
    try:
        reply = json.loads(result.stdout)
        if (type(reply) is not dict or type(reply.get("stratum")) is not int
                or not 1 <= reply["stratum"] <= 15
                # The manual's JSON example uses "noleap"; NTPsec's
                # packet.py returns "no-leap". Both denote synchronized LI=0.
                or reply.get("leap") not in ("no-leap", "noleap", "add-leap", "del-leap")
                or reply.get("adjusted") is not adjusted
                or type(reply.get("offset")) not in (int, float)
                or not math.isfinite(reply["offset"])):
            return None
        stamp = datetime.datetime.fromisoformat(reply["time"])
        if stamp.tzinfo is None or not plausible_epoch(stamp.timestamp()):
            return None
        return stamp.timestamp()
    except (ValueError, TypeError, KeyError, OverflowError):
        return None


class ClockWorker:
    def __init__(self, runtime_dir=RUNTIME_DIR, persist_dir=PERSIST_DIR):
        self.runtime_dir = pathlib.Path(runtime_dir)
        self.persist_dir = pathlib.Path(persist_dir)
        self.last_verified = None
        self.last_saved_monotonic = None
        self.fallback_epoch = None
        self.persistence_warning = False

    def log(self, message):
        # The parent timestamps each line and reopens its current log file.
        # A lifetime append descriptor would keep writing to a rotated log.
        with contextlib.suppress(BrokenPipeError):
            # The logger also receives SIGTERM during a service stop. A closed
            # pipe must not interrupt the finally block that restarts NTP.
            print(f"clock: {message}", flush=True)

    def status(self, state, attempt, source=None):
        document = {"schema": 1, "state": state, "attempt": attempt,
                    "source": source, "observed_utc": utc(time.time()),
                    "uptime_seconds": round(time.monotonic(), 1),
                    "last_verified_utc": self.last_verified,
                    "fallback_utc": (utc(self.fallback_epoch)
                                     if self.fallback_epoch else None)}
        try:
            write_state(self.runtime_dir, "status.json", document)
        except OSError as error:
            self.log(f"Could not publish clock status: {error}")

    def daemon_synced(self):
        result = command(["ntpq", "-n", "-c", "rv 0 leap,stratum", "127.0.0.1"])
        if result is None or result.returncode != 0:
            return False
        leap = re.search(r"\bleap=(0?[012])(?=,|\s|$)", result.stdout)
        stratum = re.search(r"\bstratum=(\d+)(?=,|\s|$)", result.stdout)
        # A configured local/undisciplined clock is not network verification.
        return bool(leap and stratum and 1 <= int(stratum[1]) <= 15
                    and re.search(r"\bsync_ntp\b", result.stdout))

    @contextlib.contextmanager
    def exclusive_clock(self):
        """Pause active clock services for a step, then restore even on exit."""
        restore = []
        try:
            for name in TIME_UNITS:
                result = command(["systemctl", "show", name,
                                  "--property=Id,LoadState,ActiveState"])
                if result is None:
                    raise OSError("could not inspect clock services")
                fields = dict(line.split("=", 1) for line in result.stdout.splitlines()
                              if "=" in line)
                if fields.get("LoadState") == "not-found":
                    continue
                if (result.returncode != 0
                        or fields.get("LoadState") not in ("loaded", "masked")
                        or fields.get("ActiveState") not in
                        ("active", "activating", "reloading", "inactive", "failed", "deactivating")):
                    raise OSError("could not inspect clock service load state")
                if fields.get("ActiveState") not in ("active", "activating", "reloading"):
                    continue
                unit = fields.get("Id", "")
                if unit not in TIME_UNITS:
                    raise OSError("unrecognized clock service identity")
                if unit in restore:
                    continue
                # Include it before stop: a timed-out systemctl job might
                # still complete and must always have a matching start.
                restore.append(unit)
                result = command(["systemctl", "stop", unit], timeout=10)
                if result is None or result.returncode != 0:
                    raise OSError("could not pause clock service")
            # Also guard against an unmanaged daemon, or a unit respawn.
            result = command(["ps", "-C", "ntpd,chronyd,systemd-timesyncd", "-o", "pid="])
            if result is None or result.returncode not in (0, 1) or result.stdout.strip():
                raise OSError("another clock daemon is still running")
            yield
        finally:
            for unit in restore:
                # Queue the start even after a stop timeout. The queue replaces
                # an outstanding stop job; never leave NTP disabled while offline.
                result = command(["systemctl", "start", "--no-block", unit], timeout=5)
                if result is None or result.returncode != 0:
                    self.log(f"WARNING: could not restart {unit}; clock retries continue")

    def restore_fallback(self):
        try:
            saved = read_state(self.persist_dir, "last-sync.json")
            if (type(saved) is not dict or saved.get("schema") != 1
                    or not plausible_epoch(saved.get("epoch"))
                    or saved.get("source") not in ("ntpd", *SERVERS)):
                return
            epoch = saved["epoch"]
            if epoch <= time.time() or self.daemon_synced():
                return
            with self.exclusive_clock():
                # Recheck after daemon stop in case it synced during startup.
                if epoch <= time.time():
                    return
                result = command(["date", "--set", f"@{epoch}"], timeout=5)
                if result is not None and result.returncode == 0:
                    self.fallback_epoch = epoch
                    self.log("Restored last verified time as an offline lower bound; "
                             "the clock is not yet synchronized this boot")
        except (OSError, ValueError, TypeError):
            # Missing, read-only, corrupt, or redirected cache never blocks NTP.
            return

    def sync_once(self):
        if self.daemon_synced() and plausible_epoch(time.time()):
            return "ntpd"
        for server in SERVERS:
            # ntpdig's per-address timeout does not bound DNS/all addresses;
            # the outer subprocess deadline covers the complete invocation.
            probe = command(["ntpdig", "-j", "-t", "3", server], timeout=15)
            if valid_ntp_reply(probe) is None:
                continue
            try:
                with self.exclusive_clock():
                    result = command(["ntpdig", "-j", "-S", "-t", "3", server],
                                     timeout=15)
                    epoch = valid_ntp_reply(result, adjusted=True)
                    # JSON is emitted before clock_settime. Require successful
                    # process exit AND confirmation that the local step took effect.
                    if epoch is not None and abs(time.time() - epoch) <= 10:
                        return server
            except OSError:
                continue
        return None

    def record_verified(self, source, attempt):
        epoch = int(time.time())
        if not plausible_epoch(epoch):
            return False
        self.last_verified = utc(epoch)
        self.status("synchronized", attempt, source)
        now = time.monotonic()
        if (self.last_saved_monotonic is None
                or now - self.last_saved_monotonic >= RECHECK_SECONDS):
            # Bound persistent writes to at most hourly during this worker's
            # lifetime. Unsynchronized/fallback wall time is never persisted.
            self.last_saved_monotonic = now
            try:
                # Avoid another SD-card write after a short reboot as well.
                try:
                    previous = read_state(self.persist_dir, "last-sync.json")
                except (OSError, ValueError, TypeError):
                    previous = {}
                if (type(previous) is dict and previous.get("schema") == 1
                        and plausible_epoch(previous.get("epoch"))
                        and previous.get("source") in ("ntpd", *SERVERS)
                        and 0 <= epoch - previous["epoch"] < RECHECK_SECONDS):
                    return True
                write_state(self.persist_dir, "last-sync.json",
                            {"schema": 1, "epoch": epoch, "source": source}, durable=True)
            except OSError as error:
                if not self.persistence_warning:
                    self.log(f"Clock synchronized, but offline fallback could not be saved: {error}")
                    self.persistence_warning = True
        return True

    def run(self):
        self.restore_fallback()
        attempt = 0
        delay = 30
        while True:
            attempt += 1
            source = self.sync_once()
            if source and self.record_verified(source, attempt):
                self.log(f"Clock synchronized using {source}; verified {self.last_verified}")
                delay = 30
                time.sleep(RECHECK_SECONDS)
                continue
            self.status("waiting_for_network_time", attempt)
            if attempt == 1 or attempt % 12 == 0:
                self.log("No verified network time yet; retrying in background. "
                         "USB recording continues independently")
            time.sleep(delay)
            delay = min(delay * 2, 300)


def main():
    import fcntl  # Linux-only; import here so unit tests can run on other hosts.

    if os.geteuid() != 0:
        raise SystemExit("clock worker must run as root")
    os.umask(0o077)
    private_directory(RUNTIME_DIR)
    lock = os.open(RUNTIME_DIR / "worker.lock",
                   os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(lock, "w") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1:
            raise SystemExit("unsafe clock worker lock")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return

        def stop(_signal, _frame):
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        ClockWorker().run()


if __name__ == "__main__":
    main()
