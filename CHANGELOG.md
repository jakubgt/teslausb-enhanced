# Changelog

All notable changes to this private TeslaUSB distribution are documented here.
The project uses semantic versioning for its own releases while retaining the
upstream TeslaUSB history and MIT license.

## [1.2.0-rc.5] - 2026-08-18

Fifth release candidate for the downloadable Raspberry Pi Zero 2 W image. This
candidate must be built from the rc.5 source; the previously published rc.4
image does not contain these repairs.

### Runtime corrections added 2026-09-04

- The bundled dashboard has a collapsible Advanced maintenance panel with
  read-only SSH status, a validated copyable connection command, and bounded
  downloads of saved diagnostics and maintenance logs. It adds no browser
  shell, SSH configuration mutations, or extra sudo privileges. Diagnostic
  generation now requires an explicit action instead of running on page load.
- Periodic snapshots acquire the shared storage lock before disconnecting USB.
  Busy cleanup defers the snapshot instead of holding the camera drive offline
  while old snapshots are deleted. The inherited lock descriptor is checked
  against the actual snapshots directory.
- Startup and periodic snapshots reconnect USB immediately after the immutable
  copy-on-write copy, before snapshot filesystem checks, indexing, comparison,
  and duplicate deletion. Archive operations retain their separate disconnected
  workflow. Live encrypted or uninspectable recordings still block snapshots.
- Network time synchronization runs independently of archive configuration,
  with bounded attempts and background retries. Verified time is cached as an
  explicitly unsynchronized offline lower bound; diagnostics report the last
  verification separately from the current clock.
- Dashboard USB status uses the active camera LUN, controller binding, and
  host connection state. A prepared gadget no longer implies a connected
  camera drive, and connection status does not claim that Tesla is recording.
  Binary storage quantities are labeled GiB/MiB.
- USB re-export refuses live image mountpoints that remain mounted, including
  failed-unmount recovery. Worker processes receive graceful stop signals so
  clock-service restoration is not skipped during application maintenance.
- These changes extend the still-unpublished rc.5 source candidate. They do not
  replace any published image or constitute physical-hardware validation.

### Fixed

- First-boot command-line normalization removes the standalone Raspberry Pi OS
  `resize` trigger, preserves the generated root identity and unrelated
  options, and enforces exactly one `rootwait` plus one `modules-load` token
  whose module list begins with `dwc2,g_ether`. Deduplicated extra modules are
  preserved. Image verification now rejects any image that violates those
  invariants.
- Transaction recovery is installed only after the backing-file layout has
  created and mounted `/mutable`, preventing the first setup from blocking on a
  mount that cannot exist yet.
- Completed read-only boots no longer emit harmless boot-log write errors, and
  a failed `run_once` hook remains available for a later retry.
- The read-write remount helper resolves the real boot mount behind the
  `/teslausb` link, verifies both root and boot postconditions, and fails
  explicitly instead of silently leaving `/boot/firmware` read-only.
- Camera-only diagnostics no longer report the optional media-drive web mount
  as missing; that mount is required only when a Music, LightShow, or Boombox
  image exists.
- An empty `TeslaCam/EncryptedClips` placeholder is treated as clear while any
  file, hidden entry, directory, link, non-directory object, or unknown
  inspection state remains protected. Unknown results invalidate stale
  dashboard status instead of leaving an earlier clear result visible.
- The offline configuration wizard no longer contains mojibake-prone text and
  validates `CAM_SIZE` against the advertised microSD capacity. Unsupported,
  unitless, overflowing, undersized, and over-capacity values are rejected.
- Configuration validators accept only size units implemented by the runtime,
  preventing generated settings from reaching invalid shell arithmetic.

### Documentation

- Added conservative camera-image ceilings for common microSD capacities and
  clarified the difference between decimal card labels and GiB configuration
  values, including the reserve needed for system partitions, metadata,
  snapshots, and optional media images.
- Recorded the rc.4 first-boot resize defect as a known published-image issue
  rather than associating that artifact with the rc.5 source repairs.

## [1.2.0-rc.4] - 2026-08-08

Fourth release candidate for the downloadable Raspberry Pi Zero 2 W image. It
supersedes the unpublished `v1.2.0-rc.3` draft; the rc.3 native image build
completed, but post-build verification failed before any image assets were
uploaded or published.

### Fixed

- Offline image verification now runs the trusted checked-in verifier with the
  privileges required to inspect root-only log, network, and credential paths,
  then validates and returns only the generated manifest outputs to the Actions
  runner account.
- Loop-device attach and detach calls use syntax compatible with the hosted
  Ubuntu arm64 runner while retaining canonical image paths and strict
  `/dev/loopN` validation before cleanup.
- Fresh release tags are validated from GitHub's creation response and given a
  bounded visibility interval before draft creation, avoiding the tag-to-release
  propagation race observed during the rc.3 build without blindly retrying a
  release creation request.

All feature, security, provenance, and physical-hardware testing boundaries
documented for the preceding candidates remain in effect.

### Known issue discovered after publication

- Although `rpi-resize.service` was disabled, the published rc.4 image retained
  a standalone `resize` token in `cmdline.txt`. Raspberry Pi OS therefore
  expanded the root filesystem during early boot, consuming the free space
  TeslaUSB needed for its backing-file and mutable partitions. Do not treat
  rc.4 as containing the complete resize repair; use an rc.5-or-newer image
  after it has been built and verified.

## [1.2.0-rc.3] - 2026-08-08

Third release candidate for the downloadable Raspberry Pi Zero 2 W image. It
supersedes the unpublished `v1.2.0-rc.2` draft; no rc.2 image assets were
published.

### Fixed

- Legacy `resize2fs_once` and initramfs `firstboot` cleanup is idempotent when
  current Trixie images omit those paths.
- The current Trixie `rpi-resize.service` is disabled so first boot preserves
  the unpartitioned card space required for TeslaUSB's backing-file and mutable
  partitions. Offline image verification rejects any enabled resize unit.
- The first-boot SSH marker is installed on the FAT boot partition at
  `/boot/firmware/ssh`; verification rejects the obsolete root-filesystem
  `/boot/ssh` location.
- Trixie's `rpi-swap` and `systemd-zram-generator` packages are purged alongside
  the legacy swap package, and `dpkg-db-backup.timer` is disabled. Image
  verification enforces the no-swap and disabled-backup-timer state.

All feature, security, provenance, and physical-hardware testing boundaries
documented for the preceding candidates remain in effect.

## [1.2.0-rc.2] - 2026-08-08

Second release candidate for the downloadable Raspberry Pi Zero 2 W image. It
supersedes the unpublished `v1.2.0-rc.1` draft; no rc.1 image assets were
published.

### Fixed

- The GitHub-hosted arm64 runner capacity gate now queries available bytes with
  compatible GNU `df` options while retaining the fail-closed 25 GiB minimum
  required before starting pi-gen.
- Trixie image customization removes the legacy `resize2fs_once` SysV init
  script idempotently. Current Trixie images omit that path, and its absence no
  longer aborts the image build.

All feature, security, provenance, and physical-hardware testing boundaries
documented for rc.1 remain in effect for this candidate.

## [1.2.0-rc.1] - 2026-08-08

Release candidate for a download-and-flash Raspberry Pi Zero 2 W experience.

### Added

- A release-triggered native arm64 pi-gen workflow that builds a compressed
  Raspberry Pi OS Lite Trixie image, verifies its filesystems read-only, tests
  the XZ stream, and attaches the image, SHA-256, provenance metadata, and
  installed-package manifest to the matching GitHub release.
- A self-contained offline configuration wizard on the image's boot partition.
  It recommends conservative Zero 2 W settings, generates the web password with
  Web Crypto, redacts secrets in its review, and downloads only
  `teslausb_setup.json` without network, analytics, or browser storage access.
- Static release-image verification for the MBR/FAT/ext4 layout, arm64/Trixie
  userspace, Zero 2 W boot artifacts, USB OTG configuration, locked first user,
  absent active credentials/device identity, and exact embedded-source manifest.

### Changed

- Fresh image configuration now requires an explicit uppercase two-letter
  `WIFI_COUNTRY` before enabling Wi-Fi. The build no longer hard-codes the US
  regulatory domain. Existing configs without the field remain readable and
  receive a compatibility warning.
- The recommended first-boot profile uses a 40 GB camera image, no archive
  until deliberately configured, a named timezone, web authentication, no
  destructive `DATA_DRIVE`, and temperature reporting after archive activity.
- Low-space snapshot rotation stops the current pass and reports an error if a
  snapshot release fails, preventing a tight retry loop until the next
  scheduled space check.

### Release-candidate boundary

- The image build is provenance-traceable but not claimed to be bit-for-bit
  reproducible because Debian and Raspberry Pi package repositories are not
  snapshot-pinned.
- Automated image inspection does not replace a physical-device test. This tag
  remains a prerelease until the exact published bytes complete first boot,
  2.4 GHz Wi-Fi, web authentication, USB gadget enumeration, reboot, power-cycle,
  and vehicle data-port checks on a Raspberry Pi Zero 2 W.
- `EncryptedClips` behavior remains detection/warning only. The image contains
  no user Wi-Fi, archive, Tesla, web, or SSH credentials.

## [1.1.0] - 2026-08-08

Follow-up quality-of-life release for Raspberry Pi Zero 2 W and current
Raspberry Pi OS.

### Added

- A guarded, manual USB gadget repair action with two-step dashboard
  confirmation, an exclusive operation lock, rate limiting, bounded helpers,
  backing-image preflight, and post-rebuild UDC/LUN verification.
- Transactional `/root/bin` application releases with SHA-256 manifests,
  content-addressed staging, atomic activation, service health checks,
  automatic failure recovery, and an explicit manual rollback command.
- A strict `teslausb_setup.json` format with native Boolean/integer/array
  types, a fixed variable allowlist, root-only loading without shell
  evaluation, and a safe legacy-to-JSON migration command.
- Detection-only support for Tesla `EncryptedClips`, including archive-log,
  dashboard, and `/api/v1/status` warnings.

### Changed

- Image builds now target 64-bit Raspberry Pi OS Lite based on Debian Trixie
  using pi-gen's `arm64` branch, including current `ntpsec` packages. Raspberry
  Pi Zero 2 W is an explicit supported target.
- Image builds embed the exact checked-out setup source, so private-fork first
  boot requires no GitHub token and cannot drift to an unrelated upstream
  commit.
- Passwordless sudo and cloud-init are disabled in new images. The pi-gen stage
  locks the known image password in the offline root filesystem before first
  boot or SSH startup; rc.local changes or unlocks it only when the operator
  deliberately provisions access.
- Automatic timezone discovery is pinned to tzupdate revision
  `2d41763825fcfae3f2266bf1628ce245ab285f5a` and SHA-256
  `7e6769fcf6c2a19a3492a9d62bd529714081132b12244796a4800269804857cb`;
  the bounded download remains private and cannot execute before verification.
- Legacy executable `.conf` setup files remain compatible but are deprecated
  in favor of declarative JSON.

### Safety and compatibility

- Built-in automation never opens encrypted recording contents, requests keys,
  decrypts, archives, plays, moves, or deletes them. All built-in snapshot
  triggers share a lock across live detection and the block-level copy;
  automatic cleanup retains protected or uninspectable legacy snapshots and
  excludes `EncryptedClips` mutable paths. Live detection pauses camera
  snapshots and camera-clip archiving without blocking independent music sync.
  After the trusted root archive-filter hook, literal and resolved aliases into
  `EncryptedClips` are removed before manifest creation; arbitrary root code is
  outside this built-in policy boundary.
- Transaction rollback covers managed application files only. It does not
  roll back OS packages, firmware, partitions, configuration, credentials,
  archive data, or separately managed third-party binaries.
- Bookworm and 32-bit installs are not upgraded in place. Back up the private
  configuration and flash a clean 64-bit Trixie image before restoring it.
- This GitHub release is source-only unless an explicit `.img` asset is
  attached; use the included pi-gen instructions to create the flashable image.

## [1.0.0] - 2026-08-02

Initial private enhanced release, based on upstream `main-dev` commit
`fb4ed15b46dc41a2ec7c8a7a2fe0783ce1d2ffd9`.

### Added

- Versioned local Web API, archive progress, diagnostics, speed testing, safer
  file operations, and a responsive, accessible dashboard.
- SHA-256 archive manifests, source/destination verification, bounded retries,
  stable mount-identity checks, and race-safe cleanup.
- A local configuration generator, preflight checker, and secret sanitizer.
- Expanded automated validation for shell, Python, JavaScript, nginx, sudoers,
  archive transports, setup security, BLE artifacts, and runtime behavior.

### Security

- Web authentication is enabled by default, CGI actions require same-origin
  POST requests, and nginx/sudo boundaries are narrowed.
- Setup fails closed when destructive drive selection is ambiguous and hardens
  SSH, Samba, Wi-Fi, host validation, and secret handling.
- Optional Web UI and BLE artifacts are pinned and checksum-verified; Python
  dependencies are isolated in a virtual environment.

### Changed

- Network operations and archive retries are bounded for unattended recovery.
- Installation, recovery, API, configuration, and archive-reliability guidance
  now reflect the hardened behavior.

### Known limitations

- Tesla encrypted Dashcam clips are not decrypted, archived, or played.
- Raspberry Pi OS Bookworm is the supported image base for this release.

[1.0.0]: https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.0.0
[1.1.0]: https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.1.0
[1.2.0-rc.1]: https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.2.0-rc.1
[1.2.0-rc.2]: https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.2.0-rc.2
[1.2.0-rc.3]: https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.2.0-rc.3
[1.2.0-rc.4]: https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.2.0-rc.4
[1.2.0-rc.5]: https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.2.0-rc.5
