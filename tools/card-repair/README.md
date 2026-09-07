# Targeted card maintenance builder

This is a narrowly scoped repair installer for an already-configured TeslaUSB
card. It is not an automatic updater, replacement OS image, or setup wizard. It
never changes capacity settings, boot command lines, recording files, snapshots,
or archive configuration. The operator must review each target and its baseline
before building a package.

## Build inputs

Use Python 3.9 or later and Git. Supply an exact, tested 40-character commit SHA
and a repository containing that commit. The builder reads immutable Git blobs;
working-tree edits and Windows line-ending conversions are not packaged.

The baseline JSON must contain exactly every destination in `TARGETS`, including
the service drop-in. Each entry contains `allowed_sha256` (a list of reviewed
installed-file SHA-256 hashes) and `allow_absent` (true only for genuinely new
files). The final payload hash is also accepted for safe retries. Never derive
an allowlist merely by accepting whatever unknown files happen to be installed.
The prerequisites JSON maps unchanged earlier-repair paths to exact required
hashes; these files are verified but not replaced.

For optional SSH enrollment, supply `ssh_key_setup.py` and one ordinary Ed25519
**public** key. A private key is never an input and must never be copied onto the
card or published. `--ssh-client-address` optionally checks applicable SSH Match
rules for the intended client. Existing server policy and account passwords are
not relaxed or reset. The dedicated key is appended with `restrict,pty`; existing
keys and restrictions are preserved, and ambiguous custom policies fail closed.

```sh
python3 build_card_repair.py \
  --source /path/to/repository --commit FULL_TESTED_COMMIT_SHA \
  --baselines /private/reviewed-baselines.json \
  --prerequisites /private/reviewed-prerequisites.json \
  --ssh-module ./ssh_key_setup.py --public-key /private/maintenance-key.pub \
  --output /private/card-package
```

The output is `run_once`, a versioned uncompressed tar payload, `manifest.json`,
and `SHA256SUMS`. The hook embeds exact member and payload hashes and checks them
before changing installed files. **Hashes provide integrity verification, not a
digital signature or independent proof of authorship.** Obtain and review the
hook through a trusted channel too. Do not publish generated personal packages,
baseline files, keys, or client addresses in the source repository.

## Card installation: two boots

1. Back up the card's boot partition and any existing hook. Stop recording,
   disconnect the car data cable, and safely remove the card.
2. Copy the versioned tar payload to the boot partition and verify its SHA-256.
   Copy `run_once` last, without overwriting an unknown pending hook; verify its
   hash too. Preserve all unrelated card files.
3. Reinsert the card and boot the Pi through **PWR IN only**, with its USB/data
   port empty and home Wi-Fi available. Never perform maintenance while the car
   is using the Pi as storage. Allow startup checks to finish; the hook waits up
   to ten minutes for filesystem work instead of killing it to force progress.
4. Verify `TESLAUSB_RUNTIME_MAINTENANCE_APPLIED.json` and
   `teslausb-runtime-maintenance.log` on the boot partition, or inspect them via
   SSH. Success consumes `run_once` into a uniquely named `ran_once...` archive.
   The recording service deliberately stays stopped until reboot.
5. Perform a second clean reboot on **PWR IN only**, verify runtime/SSH status,
   and only then return the device to the car for a recording test.

Do not assume an LED pattern alone proves success. If the success marker is
absent, `run_once` remains, or the log reports a failure, keep the device out of
the car and inspect the log. Do not repeatedly reflash or delete the pending
journal to bypass a safety stop.

## Transaction and recovery

The installer verifies root-owned regular files, forbids symlink/unknown-target
overwrites, creates verified private backups under
`/mutable/teslausb/manual-fixes/runtime-maintenance.*`, and stops the recording
service before replacing a coherent set of scripts. An installer lock prevents
overlapping hooks; snapshot and gadget locks exclude background workers.
Ordinary unmount is allowed only for a positively identified residual live-image
loop mount. Forced/lazy unmount, image repair, and image contents are out of scope.

A persistent pending journal and service condition prevent mixed old/new scripts
from starting after an interrupted install. Rebooting with the same intact hook
and payload performs validated rollback before retrying. Backups are retained.
The pending condition is cleared only after a durable coherent install, before
the hook consumes itself, so a power loss cannot strand the service behind a
maintenance gate with no retry hook. Originally read-only root/boot mounts are
restored. The service runtime mask lasts only until the next reboot.

Run tests in this directory with `python3 -m unittest discover -v`. Full ownership,
symlink, SSH filesystem, and chroot recovery tests require a disposable Linux
environment and root privileges; Windows skips those tests. Unit tests must not
be run against a production card's root filesystem.
