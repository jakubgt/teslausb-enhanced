# Transactional application upgrades

TeslaUSB application upgrades on this release target the 64-bit Raspberry Pi
OS Trixie image. A Raspberry Pi Zero 2 W is supported when it is running the
arm64 image; its 512 MB of RAM is sufficient because candidates are staged on
the mutable data filesystem rather than held as a second in-memory runtime.

## Moving from Bookworm

Do **not** change APT sources or attempt an in-place Bookworm-to-Trixie
distribution upgrade. TeslaUSB combines a read-only root filesystem, boot
firmware, USB gadget configuration and data-disk mounts, so a partial OS major
upgrade is not recoverable through the application rollback mechanism.

To move from Bookworm:

1. Preserve `/root/teslausb_setup.json` (or the legacy
   `/root/teslausb_setup_variables.conf`), BLE keys, and any locally maintained
   archive-filter script.
2. Verify that archived recordings are present on the archive destination.
3. Flash a clean current 64-bit TeslaUSB image built on Raspberry Pi OS Trixie.
4. Restore the configuration and keys, then run setup on the clean image.
5. Reconnect the existing archive. Do not copy old OS files over the Trixie
   root filesystem.

The upgrade preflight refuses Raspberry Pi OS major version 12 with this same
instruction. It also refuses non-arm64 kernels, unfinished installations,
unsupported hardware, and systems without the required free staging space.

## What is transactional

During `setup-teslausb upgrade`, application files destined for `/root/bin`
are redirected to a private candidate below
`/mutable/teslausb/application-releases/staging`. Every copied file is checked
immediately with SHA-256. Finalization writes a sorted checksum manifest and a
strict release metadata file containing the version, OS major, architecture,
and source-tree digest.

The first transactional upgrade captures the corresponding live files in a
content-addressed bootstrap release. Stable `/root/bin` links then resolve
through one `current` link. Activation is one atomic link replacement, followed
by runtime syntax checks and required service restart/health checks. The
required service must remain active for seven seconds (longer than its
five-second automatic-restart delay) without increasing systemd's restart
counter, so a briefly active crash loop cannot be promoted. Only a healthy
candidate becomes `last-known-good`; otherwise `current` is restored to the
prior release and the old services are restarted.

Before changing `current`, the manager durably writes a `pending-activation`
journal naming both releases. Signals trigger immediate recovery. A dedicated
systemd oneshot, required before `teslausb.service`, performs the same recovery
on the next boot after an uncatchable process kill or power loss. The journal is
removed only after health succeeds and the new `last-known-good` pointer is
durable. `status` reports whether a pending activation exists, and root can run
`teslausb-upgrade recover` explicitly if diagnosing an interrupted activation.

Upgrade preparation also fails closed: the required TeslaUSB service must stop,
an installed optional service must stop, the USB gadget must be detached, and
every mounted archive/backing path must unmount. An absent optional service,
mount, or already-detached gadget is accepted. A setup or boot change that
requires a reboot aborts and discards the candidate with instructions to reboot
and retry; the upgrade wrapper never reboots between preparation and atomic
finalization.

Useful root-only commands after installation are:

```text
/root/bin/teslausb-upgrade status
/root/bin/teslausb-upgrade recover
/root/bin/teslausb-upgrade verify /mutable/teslausb/application-releases/releases/<digest>
/root/bin/teslausb-upgrade rollback
```

No additional passwordless-sudo permission is installed for these commands.
Run them from an explicit `sudo -i` session.

## Transaction boundary

The rollback covers version-controlled application entrypoints installed in
`/root/bin`. It does not roll back Raspberry Pi OS packages, boot firmware,
partition changes, disk images, administrator configuration, credentials,
archive data, or separately content-addressed third-party artifacts. Preflight
checks run before services are stopped, and application activation happens only
after the normal setup work succeeds, but a clean image remains the recovery
path for an interrupted OS or storage migration.

Releases are retained rather than automatically deleted. This keeps the last
known-good payload available after a reboot or power loss; administrators can
remove old, inactive digest directories later after confirming the new release
in the car.
