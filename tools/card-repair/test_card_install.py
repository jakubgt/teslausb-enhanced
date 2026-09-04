import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

import card_install as repair


class PayloadTests(unittest.TestCase):
    def test_verified_regular_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, entries = self.payload(tmp)
            self.assertEqual(repair.load_payload(path, repair.digest(path.read_bytes()), entries), {"helper.sh": b"#!/bin/sh\ntrue\n"})

    def payload(self, tmp, kind="regular", duplicate=False):
        data = b"#!/bin/sh\ntrue\n"
        path = Path(tmp) / "payload.tar"
        with tarfile.open(path, "w", format=tarfile.USTAR_FORMAT) as archive:
            entry = tarfile.TarInfo("helper.sh")
            entry.size = len(data)
            if kind == "link":
                entry.type = tarfile.SYMTYPE
                entry.linkname = "/etc/shadow"
                entry.size = 0
            if kind == "traversal":
                entry.name = "../helper.sh"
            archive.addfile(entry, io.BytesIO(data))
            if duplicate:
                archive.addfile(entry, io.BytesIO(data))
        return path, [{"member": "helper.sh", "sha256": repair.digest(data)}]

    def test_rejects_bad_archive_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, entries = self.payload(tmp)
            with self.assertRaisesRegex(repair.RepairError, "checksum"):
                repair.load_payload(path, "0" * 64, entries)

    def test_rejects_links_paths_duplicates_and_member_corruption(self):
        for kind, duplicate in (("link", False), ("traversal", False), ("regular", True)):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                path, entries = self.payload(tmp, kind, duplicate)
                with self.assertRaises(repair.RepairError):
                    repair.load_payload(path, repair.digest(path.read_bytes()), entries)
        with tempfile.TemporaryDirectory() as tmp:
            path, entries = self.payload(tmp)
            entries[0]["sha256"] = "0" * 64
            with self.assertRaisesRegex(repair.RepairError, "member checksum"):
                repair.load_payload(path, repair.digest(path.read_bytes()), entries)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fs = repair.RootFS(Path(self.temp.name), check_ownership=False)
        for name in ("/root/bin", "/etc/systemd/system/teslausb.service.d", repair.BACKUP_PARENT):
            self.fs.path(name).mkdir(parents=True, exist_ok=True)
        self.backup = repair.BACKUP_PARENT + "/runtime-maintenance.test123"
        self.fs.path(self.backup).mkdir()
        self.fs.atomic("/root/bin/old.sh", b"old", 0o755)
        self.contents = {"old.sh": b"new", "new.sh": b"helper", "40-card-maintenance.conf": repair.DROPIN_DATA}
        entries = []
        for destination, member, original in (("/root/bin/old.sh", "old.sh", b"old"),
                                              ("/root/bin/new.sh", "new.sh", None),
                                              (repair.DROPIN, "40-card-maintenance.conf", None)):
            entries.append({"destination": destination, "member": member,
                "sha256": repair.digest(self.contents[member]), "mode": 0o644 if member.endswith(".conf") else 0o755,
                "allow_absent": original is None,
                "allowed_sha256": [repair.digest(self.contents[member])] + ([repair.digest(original)] if original else [])})
        self.config = {"install_id": "test123", "entries": entries}
        self.tx = repair.FileTransaction(self.fs, self.config, self.contents)

    def prepare(self):
        state = self.tx.prepare(self.tx.preflight(), self.backup)
        self.tx.persist(state)
        return state

    def test_success_installs_coherent_files_and_condition_first(self):
        state = self.prepare()
        seen = []
        self.tx.install(state, lambda index: seen.append(self.fs.path(repair.DROPIN).read_bytes()))
        self.tx.verify_final()
        self.assertEqual(seen[0], repair.DROPIN_DATA)
        self.assertEqual(self.fs.path("/root/bin/old.sh").read_bytes(), b"new")
        self.assertTrue(self.fs.path(repair.PENDING).is_file())

    def test_failure_after_every_atomic_write_restores_every_original(self):
        for failure_index in range(3):
            with self.subTest(failure_index=failure_index):
                state = self.prepare()
                def fail(index):
                    if index == failure_index:
                        raise RuntimeError("injected failure")
                with self.assertRaisesRegex(RuntimeError, "injected"):
                    self.tx.install(state, fail)
                self.tx.rollback(state)
                self.assertEqual(self.fs.path("/root/bin/old.sh").read_bytes(), b"old")
                self.assertFalse(self.fs.path("/root/bin/new.sh").exists())
                self.assertFalse(self.fs.path(repair.DROPIN).exists())
                self.assertFalse(self.fs.path(repair.PENDING).exists())

    def test_recovery_uses_durable_journal(self):
        state = self.prepare()
        self.tx.install(state)
        loaded = json.loads(self.fs.path(repair.PENDING).read_text())
        recovered = repair.FileTransaction(self.fs, self.config, self.contents)
        recovered.rollback(loaded)
        self.assertEqual(self.fs.path("/root/bin/old.sh").read_bytes(), b"old")

    def test_unknown_baseline_fails_before_mutation(self):
        self.fs.atomic("/root/bin/old.sh", b"customized")
        with self.assertRaisesRegex(repair.RepairError, "Unknown customized"):
            self.tx.preflight()
        self.assertFalse(self.fs.path(repair.PENDING).exists())

    def test_prior_repairs_are_required_but_never_replaced(self):
        self.config["prerequisites"] = {"/root/bin/old.sh": repair.digest(b"wrong")}
        with self.assertRaisesRegex(repair.RepairError, "Earlier required repair"):
            self.tx.preflight()

    def test_source_change_after_preflight_fails(self):
        records = self.tx.preflight()
        self.fs.atomic("/root/bin/old.sh", b"customized")
        with self.assertRaisesRegex(repair.RepairError, "changed after preflight"):
            self.tx.prepare(records, self.backup)

    def test_source_change_after_backup_is_not_overwritten(self):
        state = self.prepare()
        self.fs.atomic("/root/bin/old.sh", b"customized")
        with self.assertRaisesRegex(repair.RepairError, "changed after backup"):
            self.tx.install(state)
        self.assertEqual(self.fs.path("/root/bin/old.sh").read_bytes(), b"customized")
        self.assertTrue(self.fs.path(repair.PENDING).exists())

    def test_backup_corruption_blocks_rollback_and_preserves_guard(self):
        state = self.prepare()
        self.tx.install(state)
        self.fs.atomic(self.backup + "/original-00", b"corruption")
        with self.assertRaisesRegex(repair.RepairError, "backup checksum"):
            self.tx.rollback(state)
        self.assertTrue(self.fs.path(repair.PENDING).is_file())
        self.assertEqual(self.fs.path(repair.DROPIN).read_bytes(), repair.DROPIN_DATA)

    def test_unknown_change_blocks_rollback_before_any_mutation(self):
        state = self.prepare()
        self.tx.install(state)
        self.fs.atomic("/root/bin/new.sh", b"customized")
        with self.assertRaisesRegex(repair.RepairError, "Unknown modified"):
            self.tx.rollback(state)
        self.assertEqual(self.fs.path("/root/bin/old.sh").read_bytes(), b"new")
        self.assertTrue(self.fs.path(repair.PENDING).exists())

    def test_malicious_journal_paths_rejected(self):
        state = self.prepare()
        state["backup"] = "/etc"
        with self.assertRaisesRegex(repair.RepairError, "backup path"):
            self.tx.validate_journal(state)
        state["backup"] = self.backup
        state["files"][0]["destination"] = "/etc/shadow"
        with self.assertRaisesRegex(repair.RepairError, "destination"):
            self.tx.validate_journal(state)

    @unittest.skipIf(os.name == "nt", "Windows symlink creation requires privileges")
    def test_symlink_installed_file_and_parent_rejected(self):
        old = self.fs.path("/root/bin/old.sh")
        old.unlink()
        old.symlink_to(self.fs.path("/root/bin/new.sh"))
        with self.assertRaises(repair.RepairError):
            self.tx.preflight()
        old.unlink()
        parent = self.fs.path("/root/bin")
        parent.rmdir()
        parent.symlink_to(self.fs.path("/etc"), target_is_directory=True)
        with self.assertRaises(repair.RepairError):
            self.tx.preflight()


if __name__ == "__main__":
    unittest.main()
