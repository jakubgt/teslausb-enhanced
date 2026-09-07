# Runtime maintenance and verification

The runtime corrections dated 2026-09-04 and 2026-09-07 extend the unpublished rc.5 source
candidate. A GitHub source change is not automatically installed on a Pi, and
the published rc.4 image does not contain these fixes. Do not reflash a working
card just to apply a runtime repair: reflashing erases its recordings.

## Recording and storage cleanup

Tesla's live camera image and TeslaUSB's retained snapshots share physical card
space through copy-on-write. The car's displayed USB capacity is not a fixed
threshold for deleting TeslaUSB history. Low-space rotation uses exactly
`10737418240 + floor(backing_filesystem_bytes / 33)` bytes as working reserve, and
deletes the oldest eligible snapshots as necessary. Shared blocks mean deleting
one snapshot may free little space. Encrypted or uninspectable snapshots remain
protected, so their retention can prevent the normal reserve from being met.

The health panel reports actual backing-filesystem space separately from the
uninspected live camera image. A completed-release marker is evidence of one
release, not proof of recovered reserve or an end-to-end near-full-card rollover.
That rollover remains a separate, unverified test until it is observed under
normal recording. Retained recovery backups are not automatically deleted;
their allocated-block totals include potentially shared reflink extents and
must never be described as safely reclaimable space.

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

The worker checks the complete NTP daemon status, not just its leap/stratum
variables. If a DHCP-advertised time server does not respond, the existing
Google/NIST fallback sources can still verify time without changing router or
DHCP settings. A successful probe selects a numeric IPv4/IPv6 endpoint; after
request spacing, the step obtains a fresh sample from that same endpoint.
Known NTPsec clock-step diagnostics may accompany the JSON response, but a
successful process exit and confirmation of the clock adjustment are still
required. An accurate-looking wall clock alone is not synchronization proof.

Diagnostics include current UTC, the worker's last verification and fallback
state, and a bounded NTP daemon query. The dashboard distinguishes a prepared
gadget, a paused camera LUN, and a host-configured connection. Only the car or
actual clip inspection can confirm that recording is occurring. Quantities
divided by powers of 1024 are displayed as GiB/MiB, not decimal GB/MB.

## Advanced maintenance panel

Open **Tools > Advanced maintenance** in the bundled dashboard. The panel shows
read-only SSH service status and builds a copyable connection command for your
computer. It does not enable SSH, install keys, reset passwords, or run shell
commands in the browser. An active SSH service is not proof that your account
or key can log in. Port 22 is an editable, unverified default, not a detected
server setting; retain your custom port if you configured one.

The panel also reports backing/mutable space, cleanup reserve, root/boot
read-only state, finalized snapshot metadata, last known release evidence,
clock verification, and fixed-scope recovery-backup inventory. Unknown means
unknown, not empty or healthy. Snapshot completion uses finalized TOC metadata;
clock status includes the age of the worker's saved observation. The new exact,
argument-free `maintenance-health` sudo action reads this protected metadata;
it does not grant a browser shell, arbitrary path access, or SSH configuration
authority. See the [health API contract](WebAPI.md#maintenance-health-contract).

Enter your SSH account and, for a non-default dedicated key, its local private-key
**path**. The browser never needs the key file or its contents. Leave the key path
blank to use your SSH client's existing identity/agent configuration. Copy works
on the local HTTP dashboard where possible, with selectable command text as a
fallback. Keep host-key checking enabled and investigate changed-key warnings.

The panel downloads the saved diagnostic report, archive log, setup log, and
optional card-maintenance log. Diagnostic generation is a separate explicit
action. Missing or unreadable logs are reported rather than saved as successful
downloads. Downloads are bounded to the latest 8 MiB, and a truncated download
is identified. Review reports for network names, paths, and other personal data
before sharing them. No private SSH files are exposed by these endpoints.

The alternative, separately distributed interface under `/new/` is not changed;
use the bundled interface (`/?ui=legacy`) to access this panel.

## Viewer refresh and what its times mean

The bundled viewer opens the latest available recording day and provides a day
selector and **Refresh recordings** button. Each request rebuilds the selected
day from current index metadata; it is not a stale persistent listing cache.
Refresh does not disconnect the car, force a snapshot, or expose footage still
only in the live image. Newly recorded footage becomes visible after normal
snapshot processing/indexing completes.

The viewer separately labels the last completed snapshot, newest indexed camera
filename time in the selected day, and when this browser last refreshed the
library. These represent different events and clocks. A camera filename has no
timezone; a TOC modification time is not a clip capture timestamp. Missing
evidence is shown as unknown. Older day folders can remain listed even if their
eligible clip targets have disappeared.

Only one list scan per web-worker UID runs at once. Browser status polling is
deferred around list loading instead of adding concurrent background work.
Metadata scans time out before the browser's 30-second request limit. A failed
refresh leaves the previous library visible with an explicit stale warning;
successful refreshes replace the list rather than duplicate it. The selected
sequence/playback position is retained when the same media is still available;
empty or removed selections are handled explicitly. Request timeout, network,
and cancellation messages preserve their actual cause, including maintenance
downloads and log-tail views.

## RAM logging and next-boot checks

BusyBox's `-C` option alone does not override matching `/etc/syslog.conf` file
rules: those rules are processed before the shared-memory ring. The reviewed
service override uses `/sbin/syslogd -n -C128 -f /dev/null` so local system logs
use a bounded 128 KiB RAM ring rather than opening root-filesystem log files
during a temporary read-write maintenance window. This ordering is visible in
the [BusyBox syslogd source](https://raw.githubusercontent.com/mirror/busybox/master/sysklogd/syslogd.c).

Use `logread` to inspect that ring. It is volatile: entries wrap and are lost
when the logger restarts or the Pi reboots. Save needed evidence before either
operation. This is separate from TeslaUSB's rotating persistent
`/mutable/archiveloop.log`; a missing `/var/log/syslog` file is not by itself
proof that system logging has stopped.

Read-only setup now compares `/etc/fstab`'s mountpoint field exactly. The old
`grep -w /var/log` check also matched `/var/log/nginx`, incorrectly deciding that
the parent `/var/log` tmpfs already existed. If the exact parent entry is absent,
setup adds `tmpfs /var/log tmpfs nodev,nosuid,size=32M,mode=0755 0 0`. Existing
explicit parent entries are preserved. The new entry is intended for the next
normal boot, not an unreviewed mount over active log directories. Verify the
32 MiB tmpfs limit, root/boot read-only mounts, logging, Wi-Fi, and recording
after that boot; editing fstab alone does not establish those runtime results.

## A diagnosed legacy cloud-init failure

Do not disable cloud-init merely because systemd reports a degraded system.
Inspect the failing unit and its actual error first. In the diagnosed legacy
case, `cloud-init-main` explicitly reported `OSError: [Errno 30] Read-only file
system` in `all_stages`, while earlier `DataSourceNone` provisioning had already
completed. This is distinct from incomplete first boot, a network failure, or
an unknown failed service. The current image recipe already has
`ENABLE_CLOUD_INIT=0`.

Only after confirming completed provisioning and that subsequent cloud-init
work is not required, a reviewed legacy repair can create the empty
`/etc/cloud/cloud-init.disabled` marker. This is cloud-init's
[documented next-boot disable mechanism](https://docs.cloud-init.io/en/latest/howto/disable_cloud_init.html).
It does not require purging packages, running `cloud-init clean`, removing
provisioning state, or reprovisioning users/network/SSH. Do not use those actions
as substitutes. Creating the marker does not prove the next boot is healthy or
erase the current boot's failure; next-boot service and connectivity verification
is still required.

## Verify on the actual Pi

1. Install a reviewed, exact-source disruptive runtime repair with the Pi powered through
   PWR IN and disconnected from the car's USB data port. Keep a verified backup
   and do not format, resize, or remove camera images or snapshots.
   A separately reviewed viewer-only atomic update can avoid service restarts
   and USB changes; it is not permission to hot-apply filesystem or boot repairs.
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
   Look for the new `released snapshot ... at <UTC>` marker, not merely the
   older `releasing snapshot ...` intention. Download evidence before volatile
   logs are lost, and use Refresh recordings to inspect newly indexed footage.
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
