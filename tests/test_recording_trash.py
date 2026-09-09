"""Trash contracts and adversarial lifecycle tests. POSIX filesystem tests need Linux."""

import copy
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'teslausb-www/html/cgi-bin/recording-trash.py'
SPEC = importlib.util.spec_from_file_location('recording_trash', SOURCE)
trash = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trash)
EVENT = 'SentryClips/2026-09-08_12-30-00'
NAME = '2026-09-08_12-29-00-front.mp4'
NOW = 1788888600.0


def entry(event=EVENT):
    return {'id': trash.event_identity(event), 'event': event, 'state': 'trashed',
            'object': 'a' * 32, 'deleted_at': trash.utc(NOW), 'expires_at': trash.utc(NOW + trash.RETENTION),
            'bytes': 8, 'files': [{'name': NAME, 'bytes': 8, 'camera': 'front'}]}


class Contracts(unittest.TestCase):
    def test_event_identity_is_snapshot_independent_and_exact(self):
        self.assertEqual(trash.event_identity(EVENT), trash.event_identity(EVENT))
        for value in ('RecentClips/2026-09-08', 'EncryptedClips/2026-09-08_12-30-00',
                      'SentryClips/2026-02-30_12-30-00', '../' + EVENT,
                      EVENT + '/', EVENT + '\n', EVENT + '/../../etc', None, 7):
            with self.subTest(value=value), self.assertRaises(trash.TrashError):
                trash.event_identity(value)

    def test_camera_and_metadata_filename_allowlist(self):
        for name in (NAME, 'event.json', 'thumb.png', 'thumb.jpg'):
            self.assertTrue(trash.safe_name(name))
        for name in ('/etc/shadow', '../event.json', 'EncryptedClips', NAME + '.enc',
                     'x.mp4', 'event.json/..', 'event.json\n'):
            self.assertFalse(trash.safe_name(name))

    def test_single_byte_ranges_include_suffix_and_open_end(self):
        self.assertEqual(trash.parse_range('', 100), (0, 99, 200))
        self.assertEqual(trash.parse_range('bytes=20-40', 100), (20, 40, 206))
        self.assertEqual(trash.parse_range('bytes=90-', 100), (90, 99, 206))
        self.assertEqual(trash.parse_range('bytes=-5', 100), (95, 99, 206))
        self.assertEqual(trash.parse_range('bytes=0-999', 100), (0, 99, 206))
        for header in ('bytes=100-', 'bytes=5-1', 'bytes=-0', 'bytes=-', 'bytes=0-1,3-4', 'units=0-1'):
            with self.subTest(header=header), self.assertRaises(trash.TrashError):
                trash.parse_range(header, 100)

    def test_clock_rejects_stale_fallback_future_and_wall_steps(self):
        value = {'available': True, 'state': 'synchronized', 'age_seconds': 5,
                 'observed_utc': trash.utc(NOW - 5), 'last_verified_utc': trash.utc(NOW - 30)}
        self.assertTrue(trash.clock_evidence(value, NOW)['trusted'])
        for updates in ({'available': False}, {'state': 'waiting_for_network_time'},
                        {'age_seconds': 7500}, {'age_seconds': float('nan')}, {'age_seconds': True},
                        {'observed_utc': trash.utc(NOW - 100)}, {'last_verified_utc': trash.utc(NOW + 1)},
                        {'last_verified_utc': None}):
            with self.subTest(updates=updates):
                self.assertFalse(trash.clock_evidence(value | updates, NOW)['trusted'])
        self.assertFalse(trash.clock_evidence({}, NOW)['trusted'])

    def test_manifest_rejects_paths_corruption_and_shortened_retention(self):
        good = entry()
        trash.Store.validate_manifest({'schema': 1, 'events': {good['id']: good}})
        changes = (
            lambda item: item.update(object='../outside'),
            lambda item: item.update(event='EncryptedClips/2026-09-08_12-30-00'),
            lambda item: item.update(expires_at=trash.utc(NOW + 10)),
            lambda item: item.update(expires_at='bad'),
            lambda item: item['files'][0].update(name='../secret'),
            lambda item: item['files'][0].update(bytes=-1),
            lambda item: item['files'].append(dict(item['files'][0])),
            lambda item: item.update(bytes=9),
        )
        for change in changes:
            item = copy.deepcopy(good); change(item)
            with self.subTest(item=item), self.assertRaises((ValueError, trash.TrashError)):
                trash.Store.validate_manifest({'schema': 1, 'events': {good['id']: item}})

    def test_two_events_cannot_share_one_private_object(self):
        first, second = entry(), entry('SavedClips/2026-09-08_12-30-00')
        with self.assertRaises(ValueError):
            trash.Store.validate_manifest({'schema': 1, 'events': {first['id']: first, second['id']: second}})

    def test_shell_has_fixed_mutation_boundary_and_no_environment_override(self):
        wrapper = SOURCE.with_suffix('.sh').read_text()
        self.assertIn('cgi_require_method POST', wrapper)
        self.assertIn('cgi_require_mutation', wrapper)
        self.assertIn('/usr/bin/python3 -I', wrapper)
        self.assertNotIn('eval ', wrapper)
        self.assertNotIn('os.environ.get(\'TRASH_ROOT', SOURCE.read_text())

    def test_manual_purge_persists_tombstone_before_removing_owned_bytes(self):
        store = trash.Store(clock=lambda: {'trusted': False, 'now': NOW})
        item = entry(); store.document = {'schema': 1, 'events': {item['id']: item}}
        sequence = []
        with patch.object(store, 'save', side_effect=lambda: sequence.append(('save', item['state']))), \
                patch.object(store, 'remove_object', side_effect=lambda name: sequence.append(('remove', name))):
            store.delete([item['id']])
        self.assertEqual(sequence, [('save', 'deleted'), ('remove', item['object'])])
        self.assertIn(NAME, store.hidden_media())
        self.assertEqual(store.get_event(EVENT)['state'], 'deleted')

    def test_failed_tombstone_commit_never_unlinks_owned_bytes(self):
        store = trash.Store(); item = entry()
        store.document = {'schema': 1, 'events': {item['id']: item}}
        with patch.object(store, 'save', side_effect=OSError('commit failed')), patch.object(store, 'remove_object') as unlink:
            with self.assertRaises(OSError): store.delete([item['id']])
            unlink.assert_not_called()

    def test_unverified_cleanup_never_touches_private_or_source_files(self):
        store = trash.Store(clock=lambda: {'trusted': False, 'now': NOW + 99 * 86400})
        item = entry(); store.document = {'schema': 1, 'events': {item['id']: item}}
        with patch.object(store, 'save') as save, patch.object(store, 'remove_object') as unlink:
            self.assertTrue(store.cleanup()['deferred'])
            save.assert_not_called(); unlink.assert_not_called()
        self.assertEqual(item['state'], 'trashed')

    def test_selection_rejects_duplicates_wrong_types_and_deleted_ids(self):
        store = trash.Store(); item = entry()
        store.document = {'schema': 1, 'events': {item['id']: item}}
        for ids in ([], [item['id'], item['id']], ['../object'], [[item['id']]], [True], 'not-array'):
            with self.subTest(ids=ids), self.assertRaises(trash.TrashError): store.select(ids)
        item['state'] = 'deleted'
        with self.assertRaises(trash.TrashError): store.select([item['id']])

    def test_cleanup_failures_have_nonzero_service_exit_status(self):
        output = io.StringIO()
        with patch.object(trash.Store, 'locked', side_effect=OSError('private store unavailable')), contextlib.redirect_stdout(output):
            self.assertEqual(trash.main('cleanup'), 1)
        self.assertFalse(json.loads(output.getvalue())['ok'])
        self.assertNotIn('Status:', output.getvalue())

    def test_invalid_json_is_rejected_before_acquiring_the_private_store_lock(self):
        with patch.object(trash, 'read_request', side_effect=trash.TrashError('Incomplete JSON', 400)), \
                patch.object(trash.Store, 'locked') as lock, patch.object(trash, 'json_response') as respond:
            trash.main('move')
            lock.assert_not_called()
            respond.assert_called_once_with({'ok': False, 'error': 'Incomplete JSON'}, 400)

    def test_json_body_requires_exact_bounded_content_length_and_media_type(self):
        for length, body, content_type in (('100', b'{}', 'application/json'),
                                           ('9000', b'{}', 'application/json'),
                                           ('9' * 10000, b'{}', 'application/json'),
                                           ('2', b'{}', 'text/plain')):
            with self.subTest(length=length[:10], content_type=content_type), \
                    patch.dict(trash.os.environ, {'CONTENT_LENGTH': length, 'CONTENT_TYPE': content_type}), \
                    patch.object(trash.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(body))):
                with self.assertRaises(trash.TrashError): trash.read_request()
        with patch.dict(trash.os.environ, {'CONTENT_LENGTH': '2', 'CONTENT_TYPE': 'application/json; charset=utf-8'}), \
                patch.object(trash.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'{}'))):
            self.assertEqual(trash.read_request(), {})


class PlaybackCompatibility(unittest.TestCase):
    @staticmethod
    def box(kind, body=b'', extended=False):
        return ((1).to_bytes(4, 'big') + kind + (16 + len(body)).to_bytes(8, 'big') + body
                if extended else (8 + len(body)).to_bytes(4, 'big') + kind + body)

    def parse(self, content):
        with tempfile.TemporaryFile() as source:
            source.write(content); source.flush()
            result = trash.playback_ctts_offset(source.fileno(), len(content))
            source.seek(0)
            self.assertEqual(source.read(), content, 'Playback scanning must never modify originals')
            return result

    def movie(self, extended=False):
        nested = self.box(b'ctts', b'\0' * 8, extended)
        for container in (b'stbl', b'minf', b'mdia', b'trak', b'moov'):
            nested = self.box(container, nested, extended)
        return self.box(b'ftyp', b'isom\0\0\0\0') + self.box(b'mdat', b'not an atom: ctts') + nested

    def test_actual_ctts_is_adjusted_but_mdat_text_and_original_are_unchanged(self):
        content = self.movie()
        offset = self.parse(content)
        self.assertEqual(content[offset:offset + 4], b'ctts')
        expected = content[:offset] + b'@@@@' + content[offset + 4:]
        self.assertEqual(trash.apply_playback_patch(content, 0, offset), expected)
        self.assertIn(b'not an atom: ctts', expected)

    def test_extended_atom_sizes_are_supported_without_reencoding(self):
        content = self.movie(extended=True)
        offset = self.parse(content)
        self.assertEqual(content[offset:offset + 4], b'ctts')
        self.assertEqual(len(trash.apply_playback_patch(content, 0, offset)), len(content))

    def test_non_mp4_and_ctts_like_payload_are_never_changed(self):
        for content in (b'original-ctts', self.box(b'ftyp', b'isom') + self.box(b'mdat', self.box(b'ctts', b'fake')),
                        self.box(b'ftyp', b'isom') + self.box(b'free', self.box(b'ctts', b'fake'))):
            self.assertIsNone(self.parse(content))
            self.assertEqual(trash.apply_playback_patch(content, 0, None), content)

    def test_partial_ranges_and_chunk_boundaries_match_full_playback(self):
        content = self.movie(); offset = self.parse(content)
        expected = trash.apply_playback_patch(content, 0, offset)
        for start, end in ((offset - 2, offset + 2), (offset + 1, offset + 2), (offset + 3, offset + 9),
                           (0, offset), (offset + 4, len(content))):
            self.assertEqual(trash.apply_playback_patch(content[start:end], start, offset), expected[start:end])
        chunks = [trash.apply_playback_patch(content[start:start + 3], start, offset)
                  for start in range(0, len(content), 3)]
        self.assertEqual(b''.join(chunks), expected)
        self.assertEqual(trash.apply_playback_patch(b'cttsDATA', 2 ** 40, 2 ** 40), b'@@@@DATA')

    def test_only_first_structural_ctts_is_adjusted_as_in_legacy_fuse(self):
        content = self.movie() + self.box(b'ctts', b'second')
        offset = self.parse(content)
        adjusted = trash.apply_playback_patch(content, 0, offset)
        self.assertTrue(adjusted.endswith(b'cttssecond'))

    def test_zero_size_box_terminates_scan_instead_of_looping(self):
        content = self.box(b'ftyp', b'isom') + b'\0\0\0\0mdat' + b'ctts'
        self.assertIsNone(self.parse(content))

    def test_malformed_extended_size_and_too_small_boxes_fail_before_streaming(self):
        ftyp = self.box(b'ftyp', b'isom')
        for tail in (b'\0\0\0\1moov', b'\0\0\0\2moov', (999).to_bytes(4, 'big') + b'moov'):
            with self.subTest(tail=tail), self.assertRaises(trash.TrashError): self.parse(ftyp + tail)

    def test_atom_count_and_depth_are_bounded(self):
        ftyp = self.box(b'ftyp', b'isom')
        with self.assertRaises(trash.TrashError): self.parse(ftyp + self.box(b'free') * 4100)
        nested = self.box(b'ctts')
        for _ in range(10): nested = self.box(b'moov', nested)
        with self.assertRaises(trash.TrashError): self.parse(ftyp + nested)


@unittest.skipUnless(os.name == 'posix' and hasattr(os, 'O_NOFOLLOW'), 'Requires Linux openat/flock/statvfs semantics')
class FilesystemLifecycle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.root, self.index, self.snapshots, self.lock = (self.base / name for name in ('private', 'index', 'snapshots', 'snapshot-lock'))
        for directory in (self.root, self.index, self.snapshots, self.lock):
            directory.mkdir(mode=0o700)
        self.source = self.snapshots / 'snap-000001' / 'TeslaCam' / EVENT
        self.source.mkdir(parents=True)
        (self.source / NAME).write_bytes(b'original')
        (self.source / 'event.json').write_text('{"timestamp":"2026-09-08T12:30:00"}')
        self.event_dir = self.index / EVENT
        self.event_dir.mkdir(parents=True)
        for name in (NAME, 'event.json'):
            (self.event_dir / name).symlink_to(self.source / name)
        self.now, self.trusted = NOW, True
        self.store = trash.Store(self.root, self.index, self.snapshots, self.lock,
                                 clock=lambda: {'trusted': self.trusted, 'now': self.now})
        # Test files live on a normal temp FS; the production path requires readonly.
        self.readonly = patch.object(trash.os, 'fstatvfs', return_value=SimpleNamespace(
            f_flag=os.ST_RDONLY, f_bavail=1000000, f_frsize=4096, f_blocks=1000000))
        self.readonly.start()

    def tearDown(self):
        self.readonly.stop()
        self.temporary.cleanup()

    def test_copy_restore_survives_source_snapshot_removal_and_retrash(self):
        with self.store.locked():
            moved = self.store.move(EVENT)
            owned = moved['object']
            self.assertEqual((self.source / NAME).read_bytes(), b'original')
            self.assertIn(NAME, self.store.status()['hidden_media'])
        (self.source / NAME).unlink()
        with self.store.locked():
            self.store.restore([moved['id']])
            fd = self.store.open_owned(self.store.get_event(EVENT), NAME)
            try: self.assertEqual(os.read(fd, 64), b'original')
            finally: os.close(fd)
            self.now += 2 * 86400
            remade = self.store.move(EVENT)
            self.assertEqual(remade['object'], owned)
            self.assertEqual(trash.epoch(remade['expires_at']), self.now + trash.RETENTION)

    def test_manual_delete_retains_tombstone_and_never_deletes_source(self):
        with self.store.locked():
            moved = self.store.move(EVENT)
            self.store.delete([moved['id']])
            self.assertFalse((self.root / 'objects' / moved['object']).exists())
            self.assertTrue((self.source / NAME).exists())
            self.assertEqual(self.store.status()['tombstones'], [EVENT])
            self.assertEqual(self.store.status()['items'], [])
            self.assertIn(NAME, self.store.status()['hidden_media'])
        with self.store.locked():
            self.assertEqual(self.store.get_event(EVENT)['state'], 'deleted')

    def test_unverified_clock_blocks_move_and_defers_expiry(self):
        with self.store.locked():
            self.trusted = False
            with self.assertRaises(trash.TrashError): self.store.move(EVENT)
            self.assertEqual(self.store.document['events'], {})
            self.trusted = True; moved = self.store.move(EVENT)
            self.now += 31 * 86400; self.trusted = False
            self.assertTrue(self.store.cleanup()['deferred'])
            self.assertEqual(self.store.get_event(EVENT)['state'], 'trashed')
            self.assertTrue((self.root / 'objects' / moved['object'] / NAME).exists())
            self.trusted = True
            self.assertEqual(self.store.cleanup()['expired'], 1)
            self.assertTrue((self.source / NAME).exists())

    def test_restored_copies_do_not_expire(self):
        with self.store.locked():
            moved = self.store.move(EVENT); self.store.restore([moved['id']])
            self.now += 365 * 86400
            self.assertEqual(self.store.cleanup()['expired'], 0)
            self.assertTrue((self.root / 'objects' / moved['object'] / NAME).exists())

    def test_capacity_failure_leaves_event_visible_and_no_staging(self):
        with self.store.locked(), patch.object(self.store, 'capacity', return_value=(0, 256)):
            with self.assertRaises(trash.TrashError) as error: self.store.move(EVENT)
            self.assertEqual(error.exception.status, 507)
            self.assertEqual(self.store.document['events'], {})
            self.assertEqual(list((self.root / 'objects').iterdir()), [])

    def test_read_failure_never_commits_tombstone(self):
        with self.store.locked(), patch.object(trash.os, 'read', side_effect=OSError('I/O failed')):
            with self.assertRaises(OSError): self.store.move(EVENT)
            self.assertEqual(self.store.document['events'], {})
            self.assertEqual(list((self.root / 'objects').iterdir()), [])
        self.assertTrue((self.source / NAME).exists())

    def test_commit_failure_retains_durable_object_for_reconciliation(self):
        with self.store.locked(), patch.object(self.store, 'save', side_effect=OSError('fsync uncertain')):
            with self.assertRaises(OSError): self.store.move(EVENT)
            self.assertEqual(len(list((self.root / 'objects').iterdir())), 1)
        with self.store.locked():
            self.assertEqual(self.store.document['events'], {})
            self.store.cleanup()
            self.assertEqual(list((self.root / 'objects').iterdir()), [])

    def test_changed_clock_after_copy_aborts_without_tombstone(self):
        with self.store.locked(), patch.object(self.store, 'clock', side_effect=[
                {'trusted': True, 'now': NOW}, {'trusted': False, 'now': NOW}]):
            with self.assertRaises(trash.TrashError): self.store.move(EVENT)
            self.assertEqual(self.store.document['events'], {})
            self.assertEqual(list((self.root / 'objects').iterdir()), [])

    def test_snapshot_lock_busy_fails_before_copy(self):
        import fcntl
        fd = os.open(self.lock, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.store.locked():
                with self.assertRaises(trash.TrashError): self.store.move(EVENT)
                self.assertEqual(self.store.document['events'], {})
        finally: os.close(fd)

    def test_actual_legacy_snapshot_mnt_alias_is_translated_strictly(self):
        for name in (NAME, 'event.json'):
            (self.event_dir / name).unlink()
            (self.event_dir / name).symlink_to(self.lock / 'snap-000001' / 'mnt' / 'TeslaCam' / EVENT / name)
        with self.store.locked():
            self.assertEqual(self.store.move(EVENT)['event'], EVENT)

    def test_snapshot_alias_escape_or_encrypted_alias_is_rejected(self):
        for target in (self.base / 'secret', self.snapshots / 'snap-000001' / 'TeslaCam' / 'EncryptedClips' / NAME):
            (self.event_dir / NAME).unlink(); (self.event_dir / NAME).symlink_to(target)
            with self.store.locked():
                with self.assertRaises(trash.TrashError): self.store.move(EVENT)
                self.assertEqual(self.store.document['events'], {})

    def test_mutable_snapshot_is_rejected(self):
        with self.store.locked(), patch.object(trash.os, 'fstatvfs', return_value=SimpleNamespace(f_flag=0)):
            with self.assertRaises(trash.TrashError): self.store.move(EVENT)

    def test_symlinked_private_root_is_refused(self):
        alias = self.base / 'alias'; alias.symlink_to(self.root, target_is_directory=True)
        self.store.root = alias
        with self.assertRaises(OSError):
            with self.store.locked(): pass

    def test_corrupt_manifest_fails_closed(self):
        (self.root / 'manifest.json').write_text('{broken')
        with self.assertRaises(trash.TrashError):
            with self.store.locked(): pass

    def test_owned_file_symlink_cannot_be_read_or_restore_escaped(self):
        with self.store.locked():
            moved = self.store.move(EVENT)
            path = self.root / 'objects' / moved['object'] / NAME
            path.unlink(); path.symlink_to(self.source / NAME)
            with self.assertRaises(OSError): self.store.open_owned(moved, NAME)
            with self.assertRaises(OSError): self.store.restore([moved['id']])
            self.store.delete([moved['id']])
            self.assertTrue((self.source / NAME).exists())

    def test_owned_file_hardlink_cannot_be_served(self):
        with self.store.locked():
            moved = self.store.move(EVENT)
            path = self.root / 'objects' / moved['object'] / NAME
            path.unlink(); os.link(self.source / NAME, path)
            with self.assertRaises(trash.TrashError): self.store.open_owned(moved, NAME)
            self.store.delete([moved['id']])
            self.assertTrue((self.source / NAME).exists())

    def test_restore_rejects_missing_owned_camera_and_retains_trash_state(self):
        with self.store.locked():
            moved = self.store.move(EVENT)
            (self.root / 'objects' / moved['object'] / NAME).unlink()
            with self.assertRaises(OSError): self.store.restore([moved['id']])
            self.assertEqual(self.store.get_event(EVENT)['state'], 'trashed')


if __name__ == '__main__':
    unittest.main()
