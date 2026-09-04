# Runtime maintenance and verification

The runtime corrections dated 2026-09-04 extend the unpublished rc.5 source
candidate. A GitHub source change is not automatically installed on a Pi, and
the published rc.4 image does not contain these fixes. Do not reflash a working
card just to apply a runtime repair: reflashing erases its recordings.

## Recording and storage cleanup

Tesla's live camera image and TeslaUSB's retained snapshots share physical card
space through copy-on-write. The car's displayed USB capacity is not a fixed
threshold for deleting TeslaUSB history. Low-space rotation preserves roughly
10 GiB plus one thirty-third of the backing filesystem as working space, and
deletes the oldest eligible snapshots as necessary. Shared blocks mean deleting
one snapshot may free little space. Encrypted or uninspectable snapshots remain
protected, so their retention can prevent the normal reserve from being met.

A periodic snapshot now tries the storage lock before touching USB. If cleanup
is busy, the snapshot is deferred and the periodic worker retries after 60 seconds. Once a
snapshot's immutable copy exists, USB reconnects before slower snapshot checks,
indexing, or duplicate deletion. This removes the lock-wait and post-copy
processing from the intentional disconnect window; it does not guarantee zero
interruption or eliminate SD-card I/O contention. Startup filesystem repair and
deliberate archiving may still keep the drive unavailable while they run.

## Time and connection status

The background clock worker operates even with `ARCHIVE_SYSTEM=none`. Offline
attempts back off from 30 seconds to at most five minutes; verified time is
rechecked hourly. A saved verified timestamp can move a reset clock forward at
boot, but is only a lower bound, not proof of synchronization. Pi log times and
Tesla-generated clip filenames come from different clocks.

Diagnostics include current UTC, the worker's last verification and fallback
state, and a bounded NTP daemon query. The dashboard distinguishes a prepared
gadget, a paused camera LUN, and a host-configured connection. Only the car or
actual clip inspection can confirm that recording is occurring. Quantities
divided by powers of 1024 are displayed as GiB/MiB, not decimal GB/MB.

## Verify on the actual Pi

1. Install a reviewed, exact-source runtime repair with the Pi powered through
   PWR IN and disconnected from the car's USB data port. Keep a verified backup
   and do not format, resize, or remove camera images or snapshots.
2. Leave it on home Wi-Fi with Internet access for at least ten minutes. Download
   fresh diagnostics and `archiveloop.log`; check for `Clock synchronized` and a
   current `last_verified_utc`. An offline fallback alone is not a pass.
3. Reconnect to the car and confirm the Dashcam icon and newly playable clips.
   A fifteen-minute drive checks basic recording, but does not normally exercise
   the roughly hourly snapshot cycle. Include at least one longer normal
   recording session; do not operate the dashboard while driving.
4. When natural low-space cleanup occurs, look for `Snapshot deferred` while it
   is busy and `USB recording restored; finishing immutable snapshot processing`
   after a successful snapshot copy. Compare clip continuity across that period.
   Do not fill the card with dummy files to force this test.
5. Confirm oldest snapshot removal and newer snapshots/recordings continuing.
   The goal is a maintained working reserve, not a perfectly constant free-space
   number. Report fresh diagnostics and the full archive log if the reserve is
   not recovered or the car reports a recording problem.

## Useful next improvements

- A DHCP reservation makes the dashboard address predictable; configure it in
  the router rather than assuming a static address is unused.
- SSH key authentication avoids repeated passwords. Keep the HTTP dashboard on
  a trusted LAN/VPN; do not forward its port to the Internet.
- Add an external archive/backup if footage matters. Snapshot rotation is a
  rolling history on the same card, not protection against card failure.
- A future signed, checksum-verified runtime-update package with rollback would
  make deployment of this private fork simpler. Do not use a generic upstream
  update command unless replacing this fork's behavior is intentional.
- Build and verify the exact rc.5 image only after source validation; record a
  physical Pi/car test of those exact bytes before treating it as hardware-tested.
