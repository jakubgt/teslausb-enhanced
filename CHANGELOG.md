# Changelog

All notable changes to this private TeslaUSB distribution are documented here.
The project uses semantic versioning for its own releases while retaining the
upstream TeslaUSB history and MIT license.

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
