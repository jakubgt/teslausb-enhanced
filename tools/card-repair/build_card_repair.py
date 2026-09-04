#!/usr/bin/env python3
"""Build a deterministic card payload from immutable, tested Git blobs."""

import argparse
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

import card_install


TARGETS = [
    ("run/archiveloop", "/root/bin/archiveloop", "bash", 0o755),
    ("run/snapshot_lock.sh", "/root/bin/snapshot_lock.sh", "bash", 0o755),
    ("run/sync-time.py", "/root/bin/sync-time.py", "python", 0o755),
    ("run/enable_gadget.sh", "/root/bin/enable_gadget.sh", "bash", 0o755),
    ("run/guarded_snapshot.sh", "/root/bin/guarded_snapshot.sh", "bash", 0o755),
    ("run/make_snapshot.sh", "/root/bin/make_snapshot.sh", "bash", 0o755),
    ("run/manage_free_space.sh", "/root/bin/manage_free_space.sh", "bash", 0o755),
    ("run/release_snapshot.sh", "/root/bin/release_snapshot.sh", "bash", 0o755),
    ("setup/pi/setup-teslausb", "/root/bin/setup-teslausb", "bash", 0o755),
    ("teslausb-www/html/cgi-bin/status.sh", "/var/www/html/cgi-bin/status.sh", "bash", 0o755),
    ("teslausb-www/html/cgi-bin/api-v1.sh", "/var/www/html/cgi-bin/api-v1.sh", "bash", 0o755),
    ("teslausb-www/html/cgi-bin/maintenance.sh", "/var/www/html/cgi-bin/maintenance.sh", "bash", 0o755),
    ("teslausb-www/html/cgi-bin/maintenance.py", "/var/www/html/cgi-bin/maintenance.py", "python", 0o644),
    ("teslausb-www/html/index.html", "/var/www/html/index.html", None, 0o644),
    (None, card_install.DROPIN, None, 0o644),
]


def build(args):
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        raise ValueError("Use the exact 40-character tested commit SHA")
    baselines = json.loads(args.baselines.read_text(encoding="utf-8-sig"))
    prerequisites = json.loads(args.prerequisites.read_text(encoding="utf-8-sig"))
    if set(baselines) != {row[1] for row in TARGETS}:
        raise ValueError("Baseline destinations do not exactly match target set")
    contents = {}
    entries = []
    for source, destination, syntax, mode in TARGETS:
        if source is None:
            data = card_install.DROPIN_DATA
        else:
            data = subprocess.check_output([args.git, "-C", str(args.source), "show", args.commit + ":" + source])
        member = Path(destination).name
        if member in contents:
            raise ValueError("Duplicate flat tar name")
        final_sha = card_install.digest(data)
        baseline = baselines[destination]
        if (not isinstance(baseline, dict) or
                set(baseline) != {"allowed_sha256", "allow_absent"} or
                not isinstance(baseline["allowed_sha256"], list) or
                type(baseline["allow_absent"]) is not bool):
            raise ValueError("Baseline entry requires a hash list and a boolean allow_absent")
        allowed = set(baseline["allowed_sha256"]) | {final_sha}
        if any(not re.fullmatch(r"[0-9a-f]{64}", value) for value in allowed):
            raise ValueError("Malformed baseline SHA256")
        entry = {"member": member, "destination": destination, "sha256": final_sha,
                 "mode": mode, "allow_absent": baseline["allow_absent"],
                 "allowed_sha256": sorted(allowed)}
        if syntax:
            entry["syntax"] = syntax
        if source:
            entry["source"] = source
        entries.append(entry)
        contents[member] = data
    if args.ssh_module or args.public_key:
        if not args.ssh_module or not args.public_key:
            raise ValueError("SSH module and public key must be supplied together")
        module = args.ssh_module.read_bytes().replace(b"\r\n", b"\n")
        compile(module, "ssh_key_setup.py", "exec")
        key = args.public_key.read_bytes().replace(b"\r\n", b"\n")
        if not key.startswith(b"ssh-ed25519 ") or len(key.splitlines()) != 1:
            raise ValueError("Expected a single Ed25519 public key, not a private key")
        for member, data in (("ssh_key_setup.py", module), ("ssh-public-key.pub", key)):
            contents[member] = data
            entry = {"member": member, "sha256": card_install.digest(data)}
            if member.endswith(".py"):
                entry["syntax"] = "python"
            entries.append(entry)
    archive_bytes = io.BytesIO()
    with tarfile.open(fileobj=archive_bytes, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for entry in entries:
            data = contents[entry["member"]]
            member = tarfile.TarInfo(entry["member"])
            member.size = len(data)
            member.mode = entry.get("mode", 0o600)
            member.uid = member.gid = member.mtime = 0
            archive.addfile(member, io.BytesIO(data))
    raw = archive_bytes.getvalue()
    install_id = args.commit[:12]
    config = {"schema_version": 1, "install_id": install_id, "source_commit": args.commit,
              "payload_name": f"teslausb-runtime-maintenance-{install_id}.tar",
              "payload_sha256": card_install.digest(raw), "entries": entries,
              "prerequisites": prerequisites,
              "marker_name": "TESLAUSB_RUNTIME_MAINTENANCE_APPLIED.json",
              "log_name": "teslausb-runtime-maintenance.log"}
    if args.ssh_client_address:
        config["ssh_client_address"] = args.ssh_client_address
    installer = Path(card_install.__file__).read_text(encoding="utf-8").replace("\r\n", "\n")
    wrapper = ("#!/bin/bash\nset -Eeuo pipefail\numask 077\n"
               "# Exact tested runtime payload. Boot on PWR IN only. No footage/config changes.\n"
               "exec /usr/bin/python3 - <<'TESLAUSB_AUTHENTICATED_MAINTENANCE_PY'\n" + installer +
               "\nCONFIG = json.loads(" + repr(json.dumps(config, sort_keys=True)) + ")\n"
               "try:\n    sys.exit(run(CONFIG))\n"
               "except Exception as error:\n"
               "    print('TeslaUSB maintenance stopped safely: ' + str(error), file=sys.stderr)\n"
               "    try:\n        persist_failure_log(CONFIG, str(error))\n"
               "    except Exception as log_error:\n"
               "        print('Could not save boot failure log: ' + str(log_error), file=sys.stderr)\n"
               "    sys.exit(1)\n"
               "TESLAUSB_AUTHENTICATED_MAINTENANCE_PY\n")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / config["payload_name"]).write_bytes(raw)
    (args.output / "run_once").write_bytes(wrapper.encode())
    (args.output / "manifest.json").write_bytes(card_install.canonical_json(config))
    hashes = [f"{card_install.digest((args.output / name).read_bytes())}  {name}"
              for name in (config["payload_name"], "run_once", "manifest.json")]
    (args.output / "SHA256SUMS").write_text("\n".join(hashes) + "\n", encoding="ascii")
    print(json.dumps({"output": str(args.output), "install_id": install_id,
                      "payload_sha256": config["payload_sha256"], "entries": len(entries)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--git", default="git")
    parser.add_argument("--commit", required=True)
    parser.add_argument("--baselines", required=True, type=Path)
    parser.add_argument("--prerequisites", required=True, type=Path)
    parser.add_argument("--ssh-module", type=Path)
    parser.add_argument("--public-key", type=Path)
    parser.add_argument("--ssh-client-address")
    parser.add_argument("--output", required=True, type=Path)
    build(parser.parse_args())


if __name__ == "__main__":
    main()
