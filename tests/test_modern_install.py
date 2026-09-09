"""Regression checks for the reviewed, fixed-path deployment helper."""
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'modern_install', Path(__file__).resolve().parents[1] / 'tools/modern-install-20260908.py')
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class PublicationPermissionsTests(unittest.TestCase):
    def test_manual_publication_includes_every_bundled_modern_asset(self):
        modern = Path(__file__).resolve().parents[1] / 'teslausb-www/html/modern'
        expected = {'/var/www/html/modern/' + path.name: 0o644
                    for path in modern.iterdir() if path.is_file()}
        actual = {path: mode for path, mode in INSTALLER.DESTINATIONS.items()
                  if path.startswith('/var/www/html/modern/')}
        self.assertEqual(actual, expected)

    @unittest.skipUnless(os.name == 'posix', 'POSIX modes and umask are required')
    def test_public_assets_remain_readable_with_private_transaction_umask(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'web' / 'modern'
            mask = os.umask(0o077)
            try:
                with patch.object(INSTALLER, 'safe_directory'), patch.object(INSTALLER.os, 'chown'):
                    INSTALLER.mkdir_root(target)
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
                self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o755)
            finally:
                os.umask(mask)


if __name__ == '__main__':
    unittest.main()
