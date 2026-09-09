#!/usr/bin/python3
"""Private, copy-before-hide recording trash. Never changes a snapshot or car disk."""

import contextlib
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time
from urllib.parse import parse_qs, quote
import uuid

ROOT = Path('/backingfiles/teslausb-recording-trash')
INDEX = Path('/mutable/TeslaCam')
SNAPSHOTS = Path('/tmp/snapshots')
SNAPSHOT_LOCK = Path('/backingfiles/snapshots')
RETENTION = 30 * 86400
MAX_EVENT_BYTES = 16 * 1024 ** 3
MAX_FILES = 4096
MAX_MANIFEST = 16 * 1024 ** 2
COPY_SECONDS = 50
EVENT = re.compile(r'(SavedClips|SentryClips)/([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})\Z')
VIDEO = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-(front|back|left_repeater|right_repeater|left_pillar|right_pillar)\.mp4\Z')
IDENT = re.compile(r'[a-f0-9]{64}\Z')
OBJECT = re.compile(r'[a-f0-9]{32}\Z')
EXTRA_FILES = {'event.json', 'thumb.png', 'thumb.jpg', 'thumbnail.jpg'}


class TrashError(Exception):
    def __init__(self, message, status=409):
        super().__init__(message)
        self.status = status


def event_identity(event):
    if not isinstance(event, str) or not EVENT.fullmatch(event):
        raise TrashError('Only Saved and Sentry recording events can be moved to Trash.', 400)
    try:
        datetime.strptime(event.split('/')[1], '%Y-%m-%d_%H-%M-%S')
    except ValueError as error:
        raise TrashError('Invalid recording event date.', 400) from error
    return hashlib.sha256(event.encode('ascii')).hexdigest()


def safe_name(name):
    return isinstance(name, str) and bool(VIDEO.fullmatch(name) or name in EXTRA_FILES)


def utc(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace('+00:00', 'Z')


def epoch(text):
    if not isinstance(text, str):
        raise ValueError('Missing timestamp')
    result = datetime.fromisoformat(text.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('Missing timezone')
    return result.timestamp()


def open_directory(path):
    """Pin every directory component, refusing symlink ancestors (Linux openat)."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise TrashError('Unsafe storage path.', 503)
    descriptor = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def trusted_clock():
    """Use the existing fixed root health action; no paths/commands from HTTP."""
    try:
        spec = importlib.util.spec_from_file_location('trash_maintenance', Path(__file__).with_name('maintenance.py'))
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        clock = helper.privileged_health().get('clock', {})
        return clock_evidence(clock, time.time())
    except (OSError, ValueError, TypeError, AttributeError):
        return {'trusted': False, 'now': time.time()}


def clock_evidence(clock, now):
    try:
        age = clock.get('age_seconds')
        trusted = (clock.get('available') is True and clock.get('state') == 'synchronized'
                   and type(age) in (int, float) and math.isfinite(age) and 0 <= age <= 7200
                   and abs(now - epoch(clock.get('observed_utc')) - age) <= 15
                   and 0 <= now - epoch(clock.get('last_verified_utc')) <= 7200)
        return {'trusted': trusted, 'now': now}
    except (ValueError, TypeError, AttributeError):
        return {'trusted': False, 'now': now}


class Store:
    def __init__(self, root=ROOT, index=INDEX, snapshots=SNAPSHOTS,
                 snapshot_lock=SNAPSHOT_LOCK, clock=trusted_clock):
        self.root, self.index = Path(root), Path(index)
        self.snapshots, self.snapshot_lock = Path(snapshots), Path(snapshot_lock)
        self.clock = clock
        self.fd = None
        self.document = None

    @contextlib.contextmanager
    def locked(self):
        """All reads and writes share one nonblocking process lock and pinned root."""
        import fcntl
        self.fd = open_directory(self.root)
        lock = None
        try:
            info = os.fstat(self.fd)
            if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise TrashError('Trash storage must be private and owned by the web service.', 503)
            lock = os.open('lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                           0o600, dir_fd=self.fd)
            info = os.fstat(lock)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
                raise TrashError('Unsafe Trash lock.', 503)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise TrashError('Trash is busy. Wait for the current operation to finish.') from error
            try:
                os.mkdir('objects', 0o700, dir_fd=self.fd)
            except FileExistsError:
                pass
            objects = os.open('objects', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
            os.close(objects)
            self.document = self.read_manifest()
            yield self
        finally:
            if lock is not None:
                os.close(lock)
            os.close(self.fd)
            self.fd = None

    def read_manifest(self):
        try:
            fd = os.open('manifest.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        except FileNotFoundError:
            return {'schema': 1, 'events': {}}
        with os.fdopen(fd, 'rb') as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_MANIFEST:
                raise TrashError('Trash index is unsafe or too large.', 503)
            try:
                document = json.load(source)
                self.validate_manifest(document)
            except (ValueError, TypeError, KeyError) as error:
                raise TrashError('Trash index needs repair; recordings were not changed.', 503) from error
            return document

    @staticmethod
    def validate_manifest(document):
        if type(document) is not dict or document.get('schema') != 1 or type(document.get('events')) is not dict:
            raise ValueError('Invalid manifest')
        objects = set()
        for key, entry in document['events'].items():
            if (not isinstance(key, str) or not IDENT.fullmatch(key) or type(entry) is not dict
                    or event_identity(entry.get('event')) != key or entry.get('id') != key
                    or entry.get('state') not in ('trashed', 'restored', 'deleted')
                    or not isinstance(entry.get('object'), str) or not OBJECT.fullmatch(entry['object'])
                    or type(entry.get('files')) is not list or not 1 <= len(entry['files']) <= MAX_FILES):
                raise ValueError('Invalid entry')
            if entry['object'] in objects:
                raise ValueError('Two events cannot own the same private files')
            objects.add(entry['object'])
            deleted, expires = epoch(entry.get('deleted_at')), epoch(entry.get('expires_at'))
            if not 1577836800 <= deleted < 4102444800 or expires - deleted != RETENTION:
                raise ValueError('Invalid retention timestamps')
            names = set()
            for item in entry['files']:
                if (type(item) is not dict or not safe_name(item.get('name')) or item['name'] in names
                        or type(item.get('bytes')) is not int or not 0 <= item['bytes'] <= MAX_EVENT_BYTES):
                    raise ValueError('Invalid owned file')
                names.add(item['name'])
            if (not any(VIDEO.fullmatch(name) for name in names)
                    or entry.get('bytes') != sum(item['bytes'] for item in entry['files'])
                    or entry['bytes'] > MAX_EVENT_BYTES):
                raise ValueError('Invalid byte count')

    def save(self):
        self.validate_manifest(self.document)
        data = json.dumps(self.document, separators=(',', ':'), allow_nan=False).encode('utf-8')
        if len(data) > MAX_MANIFEST:
            raise TrashError('Trash index is full; no recordings were changed.', 507)
        name = '.manifest-' + uuid.uuid4().hex
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=self.fd)
        try:
            with os.fdopen(fd, 'wb') as target:
                target.write(data)
                target.flush()
                os.fsync(target.fileno())
            os.replace(name, 'manifest.json', src_dir_fd=self.fd, dst_dir_fd=self.fd)
            os.fsync(self.fd)
        finally:
            try:
                os.unlink(name, dir_fd=self.fd)
            except FileNotFoundError:
                pass

    def get_event(self, event):
        return self.document['events'].get(event_identity(event))

    def hidden_media(self):
        """Canonical camera names suppress cross-category aliases, including Recent."""
        return {item['name'] for entry in self.document['events'].values()
                for item in entry['files'] if VIDEO.fullmatch(item['name'])}

    def capacity(self):
        usage = os.fstatvfs(self.fd)
        free = usage.f_bavail * usage.f_frsize
        reserve = max(256 * 1024 ** 2, int(usage.f_blocks * usage.f_frsize * .05))
        return free, reserve

    def source_files(self, event):
        """Resolve only an exact final index alias to the same readonly snapshot event."""
        event_identity(event)
        group, date = event.split('/')
        directory = open_directory(self.index / group / date)
        files = []
        try:
            for name in sorted(os.listdir(directory)):
                if not safe_name(name):
                    raise TrashError('This recording contains unsupported files; it was left unchanged.')
                info = os.stat(name, dir_fd=directory, follow_symlinks=False)
                if not stat.S_ISLNK(info.st_mode):
                    raise TrashError('A recording source is not a snapshot alias; it was left unchanged.')
                target = Path(os.readlink(name, dir_fd=directory))
                # The snapshot publisher uses its backward-compatible mnt link.
                # Translate exactly that spelling, never resolve arbitrary links.
                try:
                    legacy = target.relative_to(self.snapshot_lock).parts
                except ValueError:
                    legacy = ()
                if (len(legacy) == 6 and re.fullmatch(r'snap-[0-9]{6}', legacy[0])
                        and legacy[1:] == ('mnt', 'TeslaCam', group, date, name)):
                    target = self.snapshots / legacy[0] / 'TeslaCam' / group / date / name
                try:
                    parts = target.relative_to(self.snapshots).parts
                except ValueError as error:
                    raise TrashError('Recording alias points outside snapshot storage.', 403) from error
                if (not target.is_absolute() or len(parts) != 5 or not re.fullmatch(r'snap-[0-9]{6}', parts[0])
                        or parts[1:] != ('TeslaCam', group, date, name)):
                    raise TrashError('Recording alias does not match the requested event.', 403)
                parent = open_directory(target.parent)
                try:
                    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                finally:
                    os.close(parent)
                metadata = os.fstat(fd)
                if (not stat.S_ISREG(metadata.st_mode)
                        or not os.fstatvfs(fd).f_flag & os.ST_RDONLY):
                    os.close(fd)
                    raise TrashError('Recording source is not a read-only snapshot.', 403)
                files.append((name, fd, metadata))
                if len(files) > MAX_FILES or sum(row[2].st_size for row in files) > MAX_EVENT_BYTES:
                    raise TrashError('This recording exceeds the safe Trash copy limit.', 413)
            if not any(VIDEO.fullmatch(row[0]) for row in files):
                raise TrashError('This event has no supported camera recordings.', 404)
            return files
        except BaseException:
            for _, fd, _ in files:
                os.close(fd)
            raise
        finally:
            os.close(directory)

    def move(self, event):
        import fcntl
        key = event_identity(event)
        existing = self.document['events'].get(key)
        clock = self.clock()
        if clock.get('trusted') is not True:
            raise TrashError('The Pi clock is not verified. Connect to network time before moving recordings to Trash.')
        now = clock['now']
        if existing:
            if existing['state'] == 'trashed':
                return existing
            if existing['state'] == 'deleted':
                raise TrashError('This event was already permanently deleted from this library.')
            # Restored originals are already owned: no second copy is needed.
            for item in existing['files']:
                descriptor = self.open_owned(existing, item['name'])
                os.close(descriptor)
            existing.update(state='trashed', deleted_at=utc(now), expires_at=utc(now + RETENTION))
            self.save()
            return existing
        snapshot_lock = open_directory(self.snapshot_lock)
        files, object_fd, object_name = [], None, uuid.uuid4().hex
        objects = os.open('objects', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
        committed = False
        try:
            try:
                fcntl.flock(snapshot_lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise TrashError('Snapshots are being updated. Try moving this recording again shortly.') from error
            started = time.monotonic()
            files = self.source_files(event)
            total = sum(row[2].st_size for row in files)
            free, reserve = self.capacity()
            if total + reserve > free:
                raise TrashError('Not enough free space to preserve this recording for 30 days. Empty existing Trash or download the clip first.', 507)
            os.mkdir(object_name, 0o700, dir_fd=objects)
            object_fd = os.open(object_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=objects)
            for name, source_fd, before in files:
                destination = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                      0o600, dir_fd=object_fd)
                copied = 0
                with os.fdopen(destination, 'wb') as target:
                    while True:
                        if time.monotonic() - started > COPY_SECONDS:
                            raise TrashError('Preserving this large recording took too long. Nothing was moved; download it or retry later.', 504)
                        chunk = os.read(source_fd, 1024 * 1024)
                        if not chunk:
                            break
                        target.write(chunk)
                        copied += len(chunk)
                    target.flush()
                    os.fsync(target.fileno())
                after = os.fstat(source_fd)
                if copied != before.st_size or (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
                    raise TrashError('A snapshot changed during the copy. Nothing was moved.')
            os.fsync(object_fd)
            os.fsync(objects)
            # Retention starts only once every original has been persisted.
            finished = self.clock()
            if finished.get('trusted') is not True or finished['now'] < now:
                raise TrashError('Clock verification changed during the copy. Nothing was moved.')
            now = finished['now']
            entry = {'id': key, 'event': event, 'state': 'trashed', 'object': object_name,
                     'deleted_at': utc(now), 'expires_at': utc(now + RETENTION), 'bytes': total,
                     'files': [{'name': name, 'bytes': info.st_size,
                                'camera': VIDEO.fullmatch(name).group(1) if VIDEO.fullmatch(name) else None}
                               for name, _, info in files]}
            self.document['events'][key] = entry
            # Once publication starts, retain the durable object even if rename
            # or directory fsync reports failure: the manifest may be visible.
            # Unreferenced copies are safely collected by the next cleanup.
            committed = True
            self.save()
            return entry
        finally:
            for _, fd, _ in files:
                os.close(fd)
            if object_fd is not None:
                os.close(object_fd)
            if not committed:
                self.document['events'].pop(key, None)
                self.remove_object(object_name)
            os.close(objects)
            os.close(snapshot_lock)

    def remove_object(self, name):
        """Unlink only private flat object entries. Never recurse or follow links."""
        if not OBJECT.fullmatch(name):
            raise TrashError('Unsafe owned object identifier.', 503)
        objects = os.open('objects', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
        folder = None
        try:
            try:
                folder = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=objects)
            except FileNotFoundError:
                return
            for child in os.listdir(folder):
                info = os.stat(child, dir_fd=folder, follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    raise TrashError('Unexpected directory in owned Trash storage; cleanup was stopped.', 503)
                os.unlink(child, dir_fd=folder)
            os.fsync(folder)
            os.close(folder)
            folder = None
            os.rmdir(name, dir_fd=objects)
            os.fsync(objects)
        finally:
            if folder is not None:
                os.close(folder)
            os.close(objects)

    def select(self, ids):
        if (type(ids) is not list or not 1 <= len(ids) <= 20
                or any(not isinstance(key, str) for key in ids) or len(set(ids)) != len(ids)):
            raise TrashError('Choose between 1 and 20 distinct Trash items.', 400)
        selected = []
        for key in ids:
            if not isinstance(key, str) or not IDENT.fullmatch(key):
                raise TrashError('Invalid Trash item.', 400)
            entry = self.document['events'].get(key)
            if entry is None or entry['state'] == 'deleted':
                raise TrashError('A selected Trash item is no longer available.', 404)
            selected.append(entry)
        return selected

    def restore(self, ids):
        entries = self.select(ids)
        for entry in entries:
            # Validate every owned original before promising recovery.
            for item in entry['files']:
                fd = self.open_owned(entry, item['name'])
                os.close(fd)
        for entry in entries:
            entry['state'] = 'restored'
        self.save()

    def delete(self, ids):
        entries = self.select(ids)
        if any(entry['state'] != 'trashed' for entry in entries):
            raise TrashError('Move a restored recording to Trash before permanently deleting it.')
        # Persist the tombstones before unlinking. A crash cannot resurrect aliases.
        for entry in entries:
            entry['state'] = 'deleted'
        self.save()
        for entry in entries:
            self.remove_object(entry['object'])

    def cleanup(self):
        clock = self.clock()
        if clock.get('trusted') is not True:
            return {'ok': True, 'deferred': True, 'reason': 'Clock is not verified; retention cleanup is paused.'}
        entries = list(self.document['events'].values())
        due = [entry for entry in entries if entry['state'] == 'trashed' and epoch(entry['expires_at']) <= clock['now']]
        for entry in due:
            entry['state'] = 'deleted'
        if due:
            self.save()
        # Retry interrupted purges and remove abandoned copy staging (no manifest owns it).
        objects = os.open('objects', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
        try:
            live = {entry['object'] for entry in entries if entry['state'] != 'deleted'}
            for name in os.listdir(objects):
                if OBJECT.fullmatch(name) and name not in live:
                    self.remove_object(name)
        finally:
            os.close(objects)
        return {'ok': True, 'expired': len(due), 'deferred': False}

    def open_owned(self, entry, name):
        if (entry['state'] not in ('trashed', 'restored') or not safe_name(name)
                or not OBJECT.fullmatch(entry['object'])):
            raise TrashError('This owned recording is not available.', 404)
        item = next((item for item in entry['files'] if item['name'] == name), None)
        if item is None:
            raise TrashError('Camera file is not part of this recording.', 404)
        objects = os.open('objects', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
        folder = None
        try:
            folder = os.open(entry['object'], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=objects)
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=folder)
        finally:
            if folder is not None:
                os.close(folder)
            os.close(objects)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid()
                or info.st_size != item['bytes']):
            os.close(fd)
            raise TrashError('An owned recording failed verification.', 503)
        return fd

    def status(self):
        clock = self.clock()
        def public(entry):
            return {key: entry[key] for key in ('id', 'event', 'deleted_at', 'expires_at', 'bytes')} | {
                'category': entry['event'].split('/')[0], 'event_time': entry['event'].split('/')[1],
                'files': [item | {'media_url': '/api/v1/trash/media?id=' + entry['id'] + '&file=' + quote(item['name'])}
                          for item in entry['files']]}
        entries = list(self.document['events'].values())
        free, reserve = self.capacity()
        return {'ok': True, 'retention_days': 30, 'clock': {'trusted': clock.get('trusted') is True},
                'items': [public(entry) for entry in entries if entry['state'] == 'trashed'],
                'restored': [public(entry) for entry in entries if entry['state'] == 'restored'],
                'tombstones': [entry['event'] for entry in entries],
                'hidden_media': sorted(self.hidden_media()),
                'free_bytes': free, 'reserve_bytes': reserve,
                'retained_bytes': sum(entry['bytes'] for entry in entries if entry['state'] != 'deleted'),
                'note': 'Trash owns preserved copies. Original snapshots, car recordings, and archive copies are unchanged; their space is not reclaimed here.'}


def parse_range(header, size):
    if not header:
        return 0, size - 1, 200
    match = re.fullmatch(r'bytes=([0-9]*)-([0-9]*)', header)
    if not match or not any(match.groups()) or size == 0:
        raise TrashError('Unsupported byte range.', 416)
    if not match[1]:
        suffix = int(match[2])
        if suffix == 0:
            raise TrashError('Unsupported byte range.', 416)
        start, end = max(0, size - suffix), size - 1
    else:
        start, end = int(match[1]), int(match[2]) if match[2] else size - 1
        end = min(end, size - 1)
    if start > end or start >= size:
        raise TrashError('Byte range is outside this recording.', 416)
    return start, end, 206


def playback_ctts_offset(fd, size):
    """Locate the first structural CTTS atom, matching cttseraser.cpp playback.

    Skip media payloads by their declared lengths; never search arbitrary bytes.
    Only small atom headers are read. A corrupt/complex tree fails before headers.
    This function and apply_playback_patch never write the preserved original.
    """
    budget = 4096
    deadline = time.monotonic() + 2
    containers = (b'moov', b'trak', b'mdia', b'minf', b'stbl')

    def atom(position, end):
        nonlocal budget
        budget -= 1
        if budget < 0 or time.monotonic() > deadline:
            raise TrashError('Recording metadata exceeds the playback scan limit. Download the original camera file.', 422)
        os.lseek(fd, position, os.SEEK_SET)
        header = os.read(fd, 8)
        if len(header) != 8:
            raise TrashError('Recording metadata is incomplete. Download the original camera file.', 422)
        length, kind, header_size = int.from_bytes(header[:4], 'big'), header[4:], 8
        if length == 1:
            extra = os.read(fd, 8)
            if len(extra) != 8:
                raise TrashError('Recording metadata is incomplete. Download the original camera file.', 422)
            length, header_size = int.from_bytes(extra, 'big'), 16
        elif length == 0:
            length = end - position
        if length < header_size or length > end - position:
            raise TrashError('Recording metadata is malformed. Download the original camera file.', 422)
        return kind, position + header_size, position + length

    def scan(start, end, depth):
        while start + 8 <= end:
            kind, payload, next_atom = atom(start, end)
            if kind == b'ctts':
                return start + 4
            if kind in containers:
                if depth >= 8:
                    raise TrashError('Recording metadata nesting exceeds the playback limit. Download the original camera file.', 422)
                found = scan(payload, next_atom, depth + 1)
                if found is not None:
                    return found
            start = next_atom
        return None

    if size < 8:
        return None
    # Non-MP4 data is not transformed, just as the established FUSE view behaves.
    os.lseek(fd, 4, os.SEEK_SET)
    if os.read(fd, 4) != b'ftyp':
        return None
    _, _, after_ftyp = atom(0, size)
    return scan(after_ftyp, size, 0)


def apply_playback_patch(data, offset, ctts_offset):
    """Patch only the overlapping fourcc bytes, including partial HTTP ranges."""
    if ctts_offset is None:
        return data
    start, end = max(offset, ctts_offset), min(offset + len(data), ctts_offset + 4)
    if start >= end:
        return data
    start, end = start - offset, end - offset
    return data[:start] + b'@' * (end - start) + data[end:]


def json_response(value, code=200):
    reason = {200: 'OK', 400: 'Bad Request', 403: 'Forbidden', 404: 'Not Found', 409: 'Conflict',
              413: 'Content Too Large', 415: 'Unsupported Media Type', 416: 'Range Not Satisfiable', 422: 'Unprocessable Content',
              503: 'Service Unavailable', 504: 'Gateway Timeout', 507: 'Insufficient Storage'}.get(code, 'Error')
    data = json.dumps(value, ensure_ascii=True, allow_nan=False).encode()
    sys.stdout.buffer.write((f'Status: {code} {reason}\r\nContent-Type: application/json; charset=utf-8\r\n'
                             f'Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Length: {len(data)}\r\n\r\n').encode() + data)


def read_request():
    if os.environ.get('CONTENT_TYPE', '').split(';')[0].strip() != 'application/json':
        raise TrashError('Send JSON for this operation.', 415)
    value = os.environ.get('CONTENT_LENGTH', '')
    if not value.isascii() or not value.isdigit() or len(value) > 4 or not 1 <= int(value) <= 8192:
        raise TrashError('Invalid JSON request length.', 400)
    try:
        raw = sys.stdin.buffer.read(int(value))
        if len(raw) != int(value):
            raise TrashError('The JSON request body was incomplete.', 400)
        data = json.loads(raw)
    except (ValueError, UnicodeError) as error:
        raise TrashError('Invalid JSON request.', 400) from error
    if type(data) is not dict:
        raise TrashError('Expected a JSON object.', 400)
    return data


@contextlib.contextmanager
def copy_deadline():
    """Bound stalled FUSE reads as well as the userspace copy loop."""
    def expired(_signum, _frame):
        raise TrashError('Preserving this recording timed out. Refresh the library to check its state; no source files were modified.', 504)
    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(58)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def main(operation):
    try:
        # Slow/incomplete request bodies must not hold the shared Trash lock.
        # The shell wrapper has already enforced method, Host, Origin, and CSRF.
        request_data = read_request() if operation in ('move', 'restore', 'delete') else None
        with Store().locked() as store:
            if operation == 'media':
                values = parse_qs(os.environ.get('QUERY_STRING', ''), strict_parsing=True)
                if set(values) != {'id', 'file'} or any(len(value) != 1 for value in values.values()):
                    raise TrashError('Invalid recording media request.', 400)
                key, name = values['id'][0], values['file'][0]
                entry = store.select([key])[0]
                fd = store.open_owned(entry, name)
                try:
                    size = os.fstat(fd).st_size
                    start, end, status_code = parse_range(os.environ.get('HTTP_RANGE', ''), size)
                    ctts_offset = playback_ctts_offset(fd, size) if VIDEO.fullmatch(name) else None
                    kind = 'video/mp4' if VIDEO.fullmatch(name) else 'application/json' if name.endswith('.json') else 'image/png' if name.endswith('.png') else 'image/jpeg'
                    head = f'Status: {status_code} ' + ('Partial Content' if status_code == 206 else 'OK') + '\r\n'
                    head += f'Content-Type: {kind}\r\nAccept-Ranges: bytes\r\nContent-Length: {max(0, end-start+1)}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n'
                    if status_code == 206:
                        head += f'Content-Range: bytes {start}-{end}/{size}\r\n'
                    # File descriptor keeps owned bytes alive after concurrent purge.
                    # Release store lock before long streams so other actions work.
                except BaseException:
                    os.close(fd)
                    raise
            elif operation == 'cleanup':
                print(json.dumps(store.cleanup(), separators=(',', ':')), flush=True)
                return
            else:
                if operation != 'status':
                    data = request_data
                    if operation == 'move' and set(data) == {'event'}:
                        with copy_deadline():
                            store.move(data['event'])
                    elif operation in ('restore', 'delete') and set(data) == {'ids'}:
                        getattr(store, operation)(data['ids'])
                    else:
                        raise TrashError('Unsupported Trash operation or fields.', 400)
                json_response(store.status())
                return
        try:
            sys.stdout.buffer.write((head + '\r\n').encode('ascii'))
            os.lseek(fd, start, os.SEEK_SET)
            remaining = max(0, end - start + 1)
            offset = start
            while remaining:
                data = os.read(fd, min(1024 * 1024, remaining))
                if not data:
                    break
                sys.stdout.buffer.write(apply_playback_patch(data, offset, ctts_offset))
                offset += len(data)
                remaining -= len(data)
        finally:
            os.close(fd)
    except TrashError as error:
        if operation == 'cleanup':
            print(json.dumps({'ok': False, 'error': str(error)}), flush=True)
            return 1
        json_response({'ok': False, 'error': str(error)}, error.status)
    except BrokenPipeError:
        # Browser cancellation must not append JSON to an already-started stream.
        return
    except (OSError, ValueError, TypeError, KeyError):
        if operation == 'cleanup':
            print(json.dumps({'ok': False, 'error': 'Trash storage is unavailable or failed verification.'}), flush=True)
            return 1
        json_response({'ok': False, 'error': 'Trash storage is unavailable or failed verification. No source recordings were modified.'}, 503)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) == 2 else 'invalid'))
