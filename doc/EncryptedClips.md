# Encrypted Dashcam clip detection

TeslaUSB detects entries inside Tesla's `TeslaCam/EncryptedClips` directory
and reports a warning. An empty placeholder directory is treated as clear.
This feature is deliberately detection-only.

When detected:

- the Status dashboard shows an **Encrypted Dashcam clips detected** warning;
- `archiveloop.log` records a warning when a guarded check detects it; and
- `/api/v1/status` reports `encrypted_clips.detected: true`.

Before any built-in camera snapshot—including the snapshot requested before a
Samba view—or archive cycle, the guarded snapshot entrypoint disconnects the
USB gadget, mounts the live camera filesystem, and checks only whether the
directory contains at least one immediate entry. A symbolic link or unexpected
non-directory at the reserved path is protected, and a state that cannot be
enumerated safely remains unknown. One shared gadget-operation lock remains
held through unmount verification and the block-level snapshot, closing the
interval in which the car could otherwise add an entry after the check. The
status scan may also report entries already visible in the newest pre-existing
snapshot view. It reads directory entries but does not open clip contents,
request or store
Tesla-account credentials, handle encryption keys, attempt decryption, or add
the recordings to the archive or web viewer. The camera cleanup paths
explicitly exclude `EncryptedClips`, so TeslaUSB does not move or delete files
inside it.

While the live path is protected or cannot be inspected safely, TeslaUSB skips
camera snapshot creation and camera-clip archiving for that cycle.
Independently configured music sync still runs, the archive connection is
closed normally, and the USB gadget is reconnected. The next startup, archive,
or scheduled snapshot cycle checks again. After the optional trusted root
`archive-filter` hook runs, TeslaUSB
removes both literal `EncryptedClips` candidates and differently named
symlinks whose resolved paths enter that directory before creating the
integrity manifest. As with any executable root hook, an administrator-supplied
filter is trusted not to modify the operating system or invoke lower-level
helpers directly; the guarantee describes TeslaUSB's built-in pipeline, not
arbitrary root code.

Pre-existing snapshots are checked for immediate entries before any automatic
release. A snapshot with a non-empty `TeslaCam/EncryptedClips` directory is
retained, while an empty directory is confirmed clear. A snapshot with a
symbolic-link/non-directory path, or one that is unreadable or unmountable, is
retained because it is protected or unknown. Low-space rotation skips those
classes rather than guessing. Cleanup of legacy/custom links below
`/mutable/TeslaCam/EncryptedClips` is excluded as well.

## What the warning means

Encrypted clips are not an archive failure. TeslaUSB's automatic archive and
web viewer support the standard unencrypted TeslaCam folders. The list API,
nginx route, and read-only FUSE viewer reject literal `EncryptedClips` paths and
resolved aliases into them; encrypted clips
must be viewed using a supported Tesla interface. Consult Tesla's
[Dashcam documentation](https://www.tesla.com/ownersmanual/model3/en_us/GUID-3BCC07CE-5EA2-4F40-99D1-27690898FF3C.html)
for current viewing and vehicle-setting options.

The warning clears after a later scan no longer finds protected entries. An
empty `EncryptedClips` directory by itself does not raise the warning. If
detection has not run yet, `/api/v1/status` returns
`encrypted_clips.available: false`; that state must not be interpreted as a
confirmed absence of encrypted recordings.

## Status file

The runtime writes a small, atomic, root-owned status document at
`/mutable/teslausb/encrypted-clips-status.json`. It contains only a schema
version, a Boolean detection result, the number of locations found, a scan
timestamp, and a fixed explanatory message. The web endpoint accepts the file
only when it is a regular non-symlink file owned by root, not group- or
world-writable, and no larger than 8 KiB.
