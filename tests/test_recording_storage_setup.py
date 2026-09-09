"""Recording storage defaults and installer preflight; no production paths are written."""

import configparser
import importlib.util
import inspect
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]
CGI = REPO / 'teslausb-www/html/cgi-bin'
SETUP = (REPO / 'setup/pi/configure-web.sh').read_text()
PREFLIGHT = re.search(r'^validate_recording_storage\(\) \{\n.*?^\}', SETUP, re.M | re.S).group(0)


def load_helper(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), CGI / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StorageContractTests(unittest.TestCase):
    def test_helpers_and_installer_use_fixed_backingfiles_roots(self):
        with patch.dict(os.environ, {'TRASH_ROOT': '/tmp/unsafe', 'CACHE_ROOT': '/tmp/unsafe',
                                     'TESLAUSB_RECORDING_ROOT': '/tmp/unsafe'}):
            trash, media = load_helper('recording-trash'), load_helper('recording-media')
        roots = ['/backingfiles/teslausb-recording-trash', '/backingfiles/teslausb-previews']
        self.assertEqual(trash.ROOT.as_posix(), roots[0])
        self.assertEqual(trash.Store().root.as_posix(), roots[0])
        self.assertEqual(media.CACHE_ROOT, roots[1])
        self.assertEqual(inspect.signature(media.PreviewCache).parameters['root'].default, roots[1])
        self.assertEqual(inspect.signature(media.preview_worker).parameters['cache_root'].default, roots[1])
        provisioned = re.search(r'^for recording_store in (.+)$', SETUP, re.M).group(1).split()
        self.assertEqual(provisioned, roots)
        self.assertIn('install -d -o www-data -g www-data -m 0700 "$recording_store"', SETUP)
        self.assertIn('[ -L "$recording_store" ]', SETUP)
        # Source aliases and snapshots must not move along with writable storage.
        self.assertEqual(trash.INDEX.as_posix(), '/mutable/TeslaCam')
        self.assertEqual(media.INDEX_ROOT, '/mutable/TeslaCam')
        self.assertEqual(trash.SNAPSHOTS.as_posix(), '/tmp/snapshots')
        self.assertEqual(media.SNAPSHOT_ROOT, '/tmp/snapshots')

    def test_timer_and_service_agree_with_private_store(self):
        service = configparser.ConfigParser(interpolation=None)
        service.read(REPO / 'setup/pi/teslausb-trash-cleanup.service')
        timer = configparser.ConfigParser(interpolation=None)
        timer.read(REPO / 'setup/pi/teslausb-trash-cleanup.timer')
        root = load_helper('recording-trash').ROOT.as_posix()
        self.assertIn('/backingfiles', service['Unit']['RequiresMountsFor'].split())
        self.assertEqual(service['Unit']['ConditionPathIsDirectory'], root)
        self.assertEqual(service['Service']['ReadWritePaths'].split(), [root])
        self.assertEqual(service['Service']['User'], 'www-data')
        self.assertEqual(service['Service']['Group'], 'www-data')
        self.assertEqual(service['Service']['UMask'], '0077')
        self.assertEqual(service['Service']['ExecStart'], '/usr/bin/python3 -I /var/www/html/cgi-bin/recording-trash.py cleanup')
        self.assertEqual(timer['Timer']['Unit'], 'teslausb-trash-cleanup.service')
        self.assertEqual(timer['Timer']['OnCalendar'], 'hourly')

    def test_storage_preflight_runs_before_web_changes(self):
        call = SETUP.index('\nvalidate_recording_storage\n')
        self.assertLess(call, SETUP.index('\nprepare_web_auth_config\n'))
        self.assertLess(call, SETUP.index('umount /var/www/html/TeslaCam'))
        self.assertIn('[ -L /backingfiles ] || ! mountpoint -q /backingfiles', PREFLIGHT)
        for mutation in ('rm ', 'mv ', 'cp ', 'install ', 'chmod ', 'chown '):
            self.assertNotIn(mutation, PREFLIGHT)

    def test_capacity_preserves_reserve_on_small_and_large_filesystems(self):
        trash = load_helper('recording-trash')
        store = trash.Store()
        store.fd = 123  # All filesystem accounting is injected; never open this descriptor.
        for total, available, expected_reserve in (
                (291_290_112, 256_223_232, 256 * 1024 ** 2),
                (508_411_654_144, 50_672_046_080, 25_420_582_707)):
            with self.subTest(total=total), patch.object(
                    trash.os, 'fstatvfs', create=True,
                    return_value=SimpleNamespace(f_blocks=total, f_bavail=available, f_frsize=1)):
                free, reserve = store.capacity()
            self.assertEqual((free, reserve), (available, expected_reserve))
            if total < 1024 ** 3:
                self.assertLess(free, reserve, 'Tiny mutable storage cannot preserve even a small event safely')
            else:
                self.assertGreater(free - reserve, trash.MAX_EVENT_BYTES)


@unittest.skipUnless(os.name == 'posix' and shutil.which('bash'), 'Linux bash is required for installer preflight fixtures')
class InstallerPreflightTests(unittest.TestCase):
    def run_preflight(self, base, *, mounted=True):
        # Execute only the read-only function, with both fixed production paths
        # translated to our temporary fixture. Never execute configure-web.sh.
        body = PREFLIGHT.replace('/mutable/teslausb-recording-trash', str(base / 'legacy'))
        body = body.replace('/backingfiles', str(base / 'backing'))
        script = 'set -eu\nmountpoint() { return ' + ('0' if mounted else '1') + '; }\n'
        result = subprocess.run(['bash', '-c', script + body + '\nvalidate_recording_storage\n'],
                                capture_output=True, text=True, timeout=5, check=False)
        return result

    def test_missing_or_symlinked_backing_mount_fails_without_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'backing').mkdir()
            result = self.run_preflight(base, mounted=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list((base / 'backing').iterdir()), [])
            (base / 'backing').rmdir()
            (base / 'real').mkdir()
            (base / 'backing').symlink_to(base / 'real', target_is_directory=True)
            self.assertNotEqual(self.run_preflight(base).returncode, 0)
            self.assertEqual(list((base / 'real').iterdir()), [])

    def test_empty_legacy_scaffolding_is_allowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'backing').mkdir()
            self.assertEqual(self.run_preflight(base).returncode, 0)
            (base / 'legacy/objects').mkdir(parents=True)
            (base / 'legacy/lock').touch()
            self.assertEqual(self.run_preflight(base).returncode, 0)

    def test_legacy_manifest_copies_staging_or_links_block_without_deletion(self):
        for entry in ('manifest.json', 'manifest.tmp', 'objects/preserved', 'objects/empty-object', 'objects-link', 'root-link'):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                (base / 'backing').mkdir()
                (base / 'legacy/objects').mkdir(parents=True)
                if entry == 'objects-link':
                    target = base / 'legacy/objects'
                    target.rmdir()
                    target.symlink_to(base / 'backing', target_is_directory=True)
                elif entry == 'root-link':
                    shutil.rmtree(base / 'legacy')
                    target = base / 'legacy'
                    target.symlink_to(base / 'backing', target_is_directory=True)
                elif entry == 'objects/empty-object':
                    target = base / 'legacy' / entry
                    target.mkdir()
                else:
                    target = base / 'legacy' / entry
                    target.write_bytes(b'preserve this existing state')
                result = self.run_preflight(base)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertTrue(target.exists(), 'Preflight must never delete old recovery state')
                if target.is_file():
                    self.assertEqual(target.read_bytes(), b'preserve this existing state')
                self.assertEqual(list((base / 'backing').iterdir()), [])


if __name__ == '__main__':
    unittest.main()
