# Changelog

All notable changes to this private TeslaUSB distribution are documented here.
The project uses semantic versioning for its own releases while retaining the
upstream TeslaUSB history and MIT license.

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
