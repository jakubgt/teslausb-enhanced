#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET

# Resolve metadata and encode the response in one process, not one realpath
# subprocess per link followed by character-at-a-time Bash JSON escaping.
# Buffer before sending headers: a failed/slow scan must not look like an empty
# or partially successful list. No recording contents are opened or modified.
response=$(python3 - "${TESLAUSB_API_RESPONSE:-text}" <<'PYTHON'
import errno
from contextlib import contextmanager
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
from urllib.parse import parse_qsl


class ScanExpired(Exception):
    pass


class IndexTooLarge(Exception):
    pass


class BadQuery(Exception):
    pass


class ScanBusy(Exception):
    pass


class ScanBudget:
    def __init__(self):
        self.entries = 0

    def consume(self):
        self.entries += 1
        if self.entries > 100000:
            raise IndexTooLarge()


def expire_scan(signum, frame):
    raise ScanExpired()


def missing_target(error):
    return error.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP)


@contextmanager
def scan_lock():
    # CGI workers share a UID. Keep only one scan active for that UID without
    # queueing more storage work; a root CLI request has its own lock. Never
    # follow, truncate, chmod or remove a pre-existing path in shared /tmp.
    import fcntl
    uid = os.geteuid()
    descriptor = os.open(f"/tmp/teslausb-videolist-{uid}.lock",
                         os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW |
                         os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != uid or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise OSError(errno.EPERM, "Unsafe recording-list lock")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ScanBusy() from error
        yield
    finally:
        os.close(descriptor)


def legacy_random_cache(value):
    # Math.random() was the entire query in older viewers, and later the _
    # value. Accept bounded decimal/scientific forms strictly below one, or
    # zero, without evaluating the token or using it as a path or command.
    return bool(re.fullmatch(r"(?:0(?:\.[0-9]{1,20})?|[1-9](?:\.[0-9]{1,19})?e-[1-9][0-9]?)", value))


def parse_day_query(query):
    if not query:
        return None
    if (len(query) > 128 or not query.isascii() or
            re.search(r"%(?![0-9a-fA-F]{2})", query)):
        raise BadQuery()
    if legacy_random_cache(query):
        return None
    try:
        fields = parse_qsl(query, keep_blank_values=True, strict_parsing=True,
                           encoding="utf-8", errors="strict", max_num_fields=2)
        if not fields:
            raise BadQuery()
        values = {}
        for name, value in fields:
            if name not in ("day", "_") or name in values:
                raise BadQuery()
            values[name] = value
        # Timestamp and legacy random cache-busters never change listing scope.
        if ("_" in values and not re.fullmatch(r"[0-9]{1,20}", values["_"]) and
                not legacy_random_cache(values["_"])):
            raise BadQuery()
        selected = values.get("day")
        if selected is None:
            return None
        if selected == "latest":
            return selected
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", selected):
            raise BadQuery()
        date.fromisoformat(selected)
        return selected
    except (ValueError, UnicodeError) as error:
        raise BadQuery() from error


def folder_day(name):
    # RecentClips uses date folders; saved/sentry events use date_time folders.
    # No arbitrary prefixes, traversal syntax or non-calendar dates are public.
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:_[0-9]{2}-[0-9]{2}-[0-9]{2})?", name):
        return None
    try:
        if len(name) == 10:
            date.fromisoformat(name)
        else:
            datetime.strptime(name, "%Y-%m-%d_%H-%M-%S")
    except ValueError:
        return None
    return name[:10]


def discover_days(root, budget):
    days = {}
    # Enumerate only real public category/event directories. Discovering choices
    # does not read links or touch snapshot/autofs targets for older days.
    with os.scandir(root) as categories:
        for category in categories:
            budget.consume()
            if (category.name not in ("RecentClips", "SavedClips", "SentryClips") or
                    not category.is_dir(follow_symlinks=False)):
                continue
            try:
                with os.scandir(category.path) as folders:
                    for folder in folders:
                        budget.consume()
                        day = folder_day(folder.name)
                        if day is not None and folder.is_dir(follow_symlinks=False):
                            days.setdefault(day, []).append(category.name + "/" + folder.name)
            except FileNotFoundError:
                # Snapshot cleanup can retire a category during discovery.
                continue
    return days


def visible_video_links(root, directories=None, budget=None, files_only=False):
    root = os.fspath(root)
    pending = [""] if directories is None else list(directories)
    paths = []
    targets = {}
    budget = budget if budget is not None else ScanBudget()
    while pending:
        relative = pending.pop()
        directory = os.path.join(root, relative) if relative else root
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    budget.consume()
                    if entry.name == "EncryptedClips":
                        continue
                    if entry.is_symlink():
                        try:
                            # Keep the per-record hot path string-based; Path
                            # construction/relative_to dominates on small Pis.
                            target = os.readlink(entry.path)
                        except OSError as error:
                            if missing_target(error):
                                continue
                            raise
                        if not os.path.isabs(target):
                            target = os.path.join(directory, target)
                        parent, name = os.path.split(target.rstrip("/") or "/")
                        index_path = relative + "/" + entry.name if relative else entry.name
                        targets.setdefault(parent, {}).setdefault(name, []).append(index_path)
                    elif entry.is_dir(follow_symlinks=False):
                        pending.append(relative + "/" + entry.name if relative else entry.name)
        except FileNotFoundError:
            # Snapshot cleanup can remove a child directory during a scan.
            # A missing index root is instead a service failure, not no clips.
            if not relative:
                raise

    # FAT filename lookups can scan a whole directory. Group requests by
    # target parent and enumerate each directory once instead of performing
    # thousands of individual lookups. Only requested names are retained.
    # Everything is rebuilt per request; no stale validity cache is served.
    for parent, requested in targets.items():
        try:
            resolved_parent = Path(parent).resolve(strict=True)
            if "EncryptedClips" in resolved_parent.parts:
                continue
            with os.scandir(resolved_parent) as entries:
                for entry in entries:
                    if not requested:
                        break
                    aliases = requested.pop(entry.name, None)
                    if not aliases or entry.name == "EncryptedClips":
                        continue
                    if entry.is_symlink():
                        try:
                            resolved = Path(entry.path).resolve(strict=True)
                        except RuntimeError:
                            continue
                        except OSError as error:
                            if missing_target(error):
                                continue
                            raise
                        if "EncryptedClips" in resolved.parts:
                            continue
                        if files_only and not resolved.is_file():
                            continue
                    elif files_only and not entry.is_file(follow_symlinks=False):
                        continue
                    paths.extend(aliases)
        except RuntimeError:
            # Python versions before 3.13 use RuntimeError for symlink loops.
            continue
        except OSError as error:
            if not missing_target(error):
                raise
    return sorted(paths, key=os.fsencode)


def newest_recording(paths):
    timestamps = []
    for path in paths:
        match = re.fullmatch(r"([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})-.+\.mp4",
                             os.path.basename(path))
        if match:
            timestamp = match[1]
            if folder_day(timestamp) is not None:
                timestamps.append(timestamp)
    # This is camera filename text, not an epoch or a claimed timezone.
    return max(timestamps, default=None)


def day_listing(root, requested_day):
    budget = ScanBudget()
    days = discover_days(root, budget)
    available = sorted(days, reverse=True)
    selected = requested_day if requested_day != "latest" else None
    paths = []
    candidates = available if requested_day == "latest" else [requested_day]
    for candidate in candidates:
        paths = visible_video_links(root, days.get(candidate, []), budget, files_only=True)
        if requested_day != "latest" or any(path.endswith(".mp4") for path in paths):
            selected = candidate
            break
        paths = []
    return {"videos": paths, "available_days": available, "selected_day": selected,
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "newest_recording": newest_recording(paths)}


def main():
    signal.signal(signal.SIGALRM, expire_scan)
    # Finish before the browser's 30-second timeout. The same process owns the
    # deadline and the scan, so abandoned requests cannot leave scanning child
    # processes behind. This does not change USB or snapshot service state.
    signal.alarm(20)
    try:
        day = parse_day_query(os.environ.get("QUERY_STRING", ""))
        with scan_lock():
            payload = ({"videos": visible_video_links("/mutable/TeslaCam")} if day is None
                       else day_listing("/mutable/TeslaCam", day))
        body = (json.dumps(payload, ensure_ascii=True, separators=(",", ":"))
                if sys.argv[1] == "json" else "\n".join(payload["videos"]))
        print(body)
        return 0
    except BadQuery:
        return 64
    except ScanBusy:
        return 77
    except ScanExpired:
        return 75
    except IndexTooLarge:
        return 76
    except OSError:
        return 74
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    sys.exit(main())
PYTHON
)
scan_status=$?
case "$scan_status" in
  0) ;;
  64) cgi_error '400 Bad Request' 'Use day=latest or day=YYYY-MM-DD with a valid calendar date, optionally with a numeric _ cache-buster. Each parameter may appear once.' ;;
  75) cgi_error '503 Service Unavailable' 'The recording index scan timed out. Wait a moment, then reload the viewer.' ;;
  76) cgi_error '503 Service Unavailable' 'The recording index is too large to list safely. Download diagnostics from Advanced maintenance.' ;;
  77) cgi_error '503 Service Unavailable' 'Another recording list is loading. Wait for it to finish, then try again.' ;;
  *) cgi_error '503 Service Unavailable' 'The recording index could not be read. Wait a moment, then reload the viewer. If this continues, download diagnostics from Advanced maintenance.' ;;
esac

if [[ "${TESLAUSB_API_RESPONSE:-}" == json ]]
then
  cgi_headers '200 OK' 'application/json; charset=utf-8'
else
  cgi_headers '200 OK' 'text/plain; charset=utf-8'
fi
printf '%s\n' "$response"
