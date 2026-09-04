# TeslaUSB Enhanced

TeslaUSB Enhanced turns a Raspberry Pi Zero 2 W into a Tesla-compatible USB
drive with automatic archiving, music storage, a local dashboard, recovery
tools, and a safer first-boot experience.

This is a private, unofficial derivative of
[`marcone/teslausb`](https://github.com/marcone/teslausb). It keeps the upstream
TeslaUSB workflow while adding a ready-to-flash image, an offline configuration
wizard, stricter security boundaries, verified archive transfers, and guarded
recovery and upgrade tools.

**Project links:** [rc.5 image target](https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.2.0-rc.5)
· [all releases](https://github.com/jakubgt/teslausb-enhanced/releases)
· [changelog](CHANGELOG.md) · [setup guide](doc/OneStepSetup.md)

> [!IMPORTANT]
> The current image is a prerelease for early testing. Back up your existing
> configuration, keys, and recordings before flashing it.

> [!CAUTION]
> Do not use the published `v1.2.0-rc.4` image for a fresh setup. Its boot
> command line still contains Raspberry Pi OS's standalone `resize` trigger,
> which can consume the card space TeslaUSB needs. This source targets rc.5;
> wait for the verified rc.5 image and checksum after these changes are merged.

## Current release

| Item | Status |
| --- | --- |
| Image release target | [`v1.2.0-rc.5`](https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.2.0-rc.5) — built and published after the rc.5 source is merged and verified |
| Latest stable source release | [`v1.1.0`](https://github.com/jakubgt/teslausb-enhanced/releases/tag/v1.1.0) — source only, no downloadable image |
| Primary hardware | Raspberry Pi Zero 2 W |
| Operating system | 64-bit Raspberry Pi OS Lite, Debian Trixie, arm64 |
| Image download | [`teslausb-enhanced-v1.2.0-rc.5-pi-zero-2w-arm64-trixie.img.xz`](https://github.com/jakubgt/teslausb-enhanced/releases/download/v1.2.0-rc.5/teslausb-enhanced-v1.2.0-rc.5-pi-zero-2w-arm64-trixie.img.xz) |
| Image SHA-256 | Use the `.sha256` asset generated for the exact rc.5 image; do not reuse the rc.4 digest |
| Source commit | Recorded in the rc.5 image metadata after the verified build |
| Hardware validation | Automated verification must pass before rc.5 publication; physical Zero 2 W and Tesla testing of the exact published bytes is still required |

The repository and release are private. Download the image while signed in to
an authorized GitHub account; Raspberry Pi Imager cannot authenticate to a
private release URL itself.

GitHub currently labels `v1.1.0` as **Latest**, but that release is source-only.
Use the rc.5 prerelease only after its image and checksum assets have been
published. The rc.4 image remains available for provenance, not for a fresh
flash.

## What this fork adds

| Area | Upgrade | Practical benefit |
| --- | --- | --- |
| Flashing | Native arm64/Trixie image builds with `.img.xz`, checksum, provenance metadata, and package manifest | Download one verified image and flash it directly with Raspberry Pi Imager |
| First boot | Self-contained `teslausb_config_wizard.html` on the boot partition | Create a conservative configuration offline without hand-editing shell code |
| Configuration | Strict `teslausb_setup.json` schema, type and range checks, fixed allowlist, safe migration, and secret sanitization | Declarative JSON values are not evaluated as shell code; unsafe or incomplete values fail before setup |
| Archive reliability | SHA-256 manifests, destination verification, stable mount identity, bounded retries, and race-safe cleanup | Transfer failures are detected before source links are released |
| Dashboard and API | Responsive status UI, diagnostics, archive progress, safer file actions, and a versioned local API | Better visibility and fewer risky manual recovery steps |
| USB recovery | Manual, two-confirmation gadget repair with shared locking, cooldowns, image preflight, and post-rebuild verification | Repairs USB gadget state without silently racing archive or snapshot operations |
| Application upgrades | Content-addressed releases, checksum validation, atomic activation, health checks, automatic recovery, and rollback | A failed managed application update can return to the previous working release |
| Encrypted recordings | `EncryptedClips` detection and warnings with guarded snapshot, cleanup, archive, and viewer boundaries | Opaque encrypted recordings stay outside built-in processing instead of being treated as normal clips |
| Security | Web authentication by default, same-origin POST actions, narrowed nginx/CGI/sudo boundaries, fail-closed drive selection, and pinned optional downloads | Reduces accidental exposure, command injection, and destructive-drive mistakes |
| Pi Zero 2 W safeguards | Locked image account, no embedded user credentials, verified `rootwait`/USB-module boot tokens, removed `resize` trigger, disabled resize/swap services, and exact embedded setup source | First boot is deterministic and does not need a private GitHub token |

For the complete version-by-version record, see the
[`CHANGELOG`](CHANGELOG.md).

## Quick start: Raspberry Pi Zero 2 W

### You need

- A Raspberry Pi Zero 2 W.
- A microSD card of at least 64 GB. A high-endurance 128 GB or larger card is
  recommended for more recording history and better write durability.
- A known-good USB data cable. Connect the Tesla to the Zero 2 W's **USB/data
  (OTG)** port, not its power-only port.
- A 2.4 GHz-capable Wi-Fi network with Internet access during initial setup.
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/).

The card sizes above are project recommendations, not Raspberry Pi hardware
limits.

### Choose a safe camera size

`CAM_SIZE` is the size of the virtual drive shown to the car. The card's label
uses decimal GB, but TeslaUSB's `G` suffix means binary GiB. Do not copy the
printed card capacity into `CAM_SIZE`: for example, `500G` is not safe on a
512 GB card. The offline wizard asks for the advertised card capacity, enforces
the matching ceiling below, and keeps that capacity choice out of the generated
JSON.

| Capacity printed on card | Maximum `CAM_SIZE` |
| ---: | ---: |
| 64 GB | `40G` |
| 128 GB | `100G` |
| 256 GB | `210G` |
| 512 GB | `440G` |
| 1 TB (1000 GB) | `880G` |
| 1.5 TB (1500 GB) | `1330G` |
| 2 TB (2000 GB) | `1780G` |

These are safety ceilings, not targets. They use the conservative rule
`floor-to-10(0.90 * advertised decimal GB - 15)`. `CAM_SIZE` must be at least
`20G`; `40G` remains the recommended starting value and leaves much more room
for filesystem metadata, copy-on-write snapshots, and normal operation. If you
configure `MUSIC_SIZE`, `LIGHTSHOW_SIZE`, `BOOMBOX_SIZE`, or
`INCREASE_ROOT_SIZE`, subtract those allocations from the table ceiling before
choosing `CAM_SIZE`.

### Flash and configure

1. After rc.5 is published, download its [`.img.xz` image](https://github.com/jakubgt/teslausb-enhanced/releases/download/v1.2.0-rc.5/teslausb-enhanced-v1.2.0-rc.5-pi-zero-2w-arm64-trixie.img.xz)
   and [checksum file](https://github.com/jakubgt/teslausb-enhanced/releases/download/v1.2.0-rc.5/teslausb-enhanced-v1.2.0-rc.5-pi-zero-2w-arm64-trixie.img.xz.sha256).
2. Verify the image digest before flashing. It must exactly match the digest in
   that rc.5 checksum asset.

   On Windows PowerShell:

   ```powershell
   Get-FileHash .\teslausb-enhanced-v1.2.0-rc.5-pi-zero-2w-arm64-trixie.img.xz -Algorithm SHA256
   ```

3. In Raspberry Pi Imager, choose **Use custom**, select the downloaded
   `.img.xz` file directly, and write it to the card. Do not extract it first.
4. Decline Raspberry Pi Imager's OS customization options. TeslaUSB uses its
   own first-boot configuration and the clean image contains no user Wi-Fi,
   archive, web, Tesla, or SSH credentials.
5. Reinsert or remount the card and open
   `teslausb_config_wizard.html` from its boot partition in a modern browser.
6. Complete the offline form and download `teslausb_setup.json`. Copy it to the
   root of the boot partition with that exact filename; remove suffixes such as
   `(1)` that a browser may add.
7. Safely eject the card, insert it into the Pi, and boot within Wi-Fi range.
   Initial setup downloads packages and can take longer than five minutes on a
   slow connection.
8. Open `http://teslausb.local/` and confirm storage, network, temperature, and
   archive status before connecting the Pi to the car.

The [one-step setup guide](doc/OneStepSetup.md) covers configuration choices,
LED stages, troubleshooting, and what happens during first boot.

## Offline configuration wizard

The recommended helper is `teslausb_config_wizard.html`, included on the
rc.5 image's boot partition. It:

- runs entirely in the browser with no network requests, analytics, remote
  scripts, form submission, or browser storage;
- generates the web password with the browser's cryptographic random-number
  generator;
- redacts secrets in its on-screen review; and
- downloads only `teslausb_setup.json` without scanning for or writing to a
  microSD card automatically.

The downloaded JSON necessarily contains your real credentials. Keep it
private, retain only an encrypted backup, and remove it from shared computers.

### Recommended first-boot profile

| Setting | Recommended starting value |
| --- | --- |
| Camera image | `CAM_SIZE: "40G"` |
| Card-size safety | Enter the capacity printed on the card; keep `CAM_SIZE` at or below the calculated ceiling |
| Archive | `ARCHIVE_SYSTEM: "none"` until local operation is confirmed |
| RecentClips archive | `ARCHIVE_RECENTCLIPS: false` |
| Wi-Fi country | Explicit physical-location ISO country code; no default is guessed (`GB`, not `UK`) |
| Time zone | A reviewed named zone such as `America/Chicago` |
| Web access | Username `teslausb` and a unique locally generated password |
| Temperature reporting | 55 °C caution, 68 °C warning, hourly logging, and post-archive reporting |
| Destructive or external options | Leave `DATA_DRIVE`, access-point mode, guest Samba, notifications, and third-party WebUI downloads unset initially |

`DATA_DRIVE` is destructive: setup may wipe and repartition the selected
whole-disk device, and ambiguous selection fails closed. Leave it unset unless
you have independently verified the exact device.

Advanced users can use the dependency-free Node.js helper at
[`tools/teslausb-config.js`](tools/teslausb-config.js) to preflight, migrate,
generate, or sanitize configurations. See the
[configuration helper guide](doc/ConfigTool.md) and
[declarative JSON reference](doc/DeclarativeConfig.md).

## Important safety and security boundaries

### Encrypted Dashcam recordings

TeslaUSB detects an `EncryptedClips` directory and reports a warning in the
dashboard, archive log, and local API. Built-in automation does not request
keys, decrypt, open, archive, play, move, or delete encrypted clip contents.

While encrypted recordings are detected, camera snapshots and camera-clip
archiving pause. Protected or uninspectable legacy snapshots are retained by
automatic cleanup, and literal or resolved aliases into `EncryptedClips` are
excluded from built-in archive and viewer paths. Independent music sync can
continue. Normal camera processing resumes after a later live check no longer
detects the directory.

This policy covers built-in automation. Arbitrary trusted root hooks remain
outside that boundary. See [encrypted clip detection](doc/EncryptedClips.md)
for the exact behavior.

### Web access

Web authentication is enabled by default, and state-changing actions require
same-origin `POST` requests. The dashboard still uses HTTP on the local
network: Basic Authentication controls access but does not encrypt traffic.
Keep TeslaUSB on a trusted private LAN or access it through a trusted VPN; do
not expose the dashboard or [local API](doc/WebAPI.md) directly to the Internet.

### Archive integrity

Archive hashes and destination verification detect incomplete or changed
transfers. They do not make an untrusted or compromised archive server
trustworthy. Protect the archive separately with appropriate access controls,
backups, and monitoring. See [archive reliability](doc/ArchiveReliability.md).

### USB gadget repair

The dashboard repair action is deliberately manual and requires two
confirmations. Disconnect the Tesla or computer cleanly before using it. The
repair briefly removes and rebuilds all exported drives; failed verification
leaves the gadget disconnected rather than presenting an unverified device.
It rebuilds the exported USB gadget only; it does not format, mount, or repair
a backing image.
See [USB gadget repair](doc/USBGadgetRepair.md).

## Upgrading an existing installation

For the cleanup-delay and independent-clock corrections, connection-status
semantics, and a safe on-device test plan, see
[runtime maintenance and verification](doc/RuntimeMaintenance.md). These changes
extend the unpublished rc.5 candidate; they are not present in the rc.4 image.

- Do **not** perform an in-place Bookworm-to-Trixie or 32-bit-to-64-bit OS
  upgrade. Back up the private configuration and keys, flash a clean arm64
  Trixie image, and restore through the JSON configuration workflow.
- Transactional application upgrades protect the managed application release
  and `/root/bin` entrypoints. They do not roll back OS packages, firmware,
  partitions, configuration, credentials, archive data, or separately managed
  third-party binaries.
- This repository is private. The image contains the exact setup source needed
  for first boot, but future source downloads do not receive an embedded GitHub
  credential, and this fork does not yet provide a signed release-asset updater.
  Prefer a new verified image unless you have deliberately configured a trusted
  authenticated update path.

See [transactional upgrades](doc/TransactionalUpgrades.md) for verification,
recovery, rollback, and the precise transaction boundary.

## Image verification and release boundary

Before publication, the release pipeline checks:

- MBR/FAT/ext4 layout and read-only filesystem access;
- arm64/Trixie identity and Raspberry Pi Zero 2 W boot artifacts;
- USB OTG configuration and the FAT-partition SSH marker;
- a locked default account and absence of active setup credentials;
- absence of SSH host keys, initialized machine identity, and random seed;
- the exact embedded source manifest and installed package inventory;
- removal of the standalone `resize` boot trigger, exact `rootwait` and USB
  module tokens, and disabled resize, swap, and package-backup services;
- XZ stream integrity, SHA-256 manifests, and uploaded GitHub asset digests.

The release also provides
[build metadata](https://github.com/jakubgt/teslausb-enhanced/releases/download/v1.2.0-rc.5/teslausb-enhanced-v1.2.0-rc.5-pi-zero-2w-arm64-trixie.image-metadata.json)
and an
[installed-package manifest](https://github.com/jakubgt/teslausb-enhanced/releases/download/v1.2.0-rc.5/teslausb-enhanced-v1.2.0-rc.5-pi-zero-2w-arm64-trixie.packages.tsv).

These checks are extensive, but they do not replace a complete physical test
of first boot, 2.4 GHz Wi-Fi, web authentication, USB enumeration, reboot,
power-cycle, archive transfer, and vehicle operation. Debian and Raspberry Pi
package repositories are not snapshot-pinned, so the recorded build is
provenance-traceable but is not guaranteed to be bit-for-bit reproducible.

## Documentation

| Task | Guide |
| --- | --- |
| Flash and first boot | [One-step setup](doc/OneStepSetup.md) |
| Configure or migrate safely | [Configuration helper](doc/ConfigTool.md) · [Declarative JSON](doc/DeclarativeConfig.md) |
| Understand encrypted clips | [Encrypted clip detection](doc/EncryptedClips.md) |
| Diagnose archive behavior | [Archive reliability](doc/ArchiveReliability.md) |
| Repair USB gadget state | [USB gadget repair](doc/USBGadgetRepair.md) |
| Upgrade or roll back application files | [Transactional upgrades](doc/TransactionalUpgrades.md) |
| Integrate with the dashboard | [Local Web API](doc/WebAPI.md) |
| Build an image from source | [Pinned pi-gen recipe](pi-gen-sources/Readme.md) |
| Review every release change | [Changelog](CHANGELOG.md) |

For general TeslaUSB concepts and hardware beyond this image's primary Zero 2
W target, consult the [upstream TeslaUSB wiki](https://github.com/marcone/teslausb/wiki).
Enhanced-fork defects should be reported in this repository rather than to the
upstream maintainers. Sanitize configuration and diagnostic output before
sharing it.

## About TeslaUSB

Single-board computers with USB OTG support can emulate a drive that a Tesla
uses for Dashcam recordings and music. Because the computer also controls the
backing storage, TeslaUSB can archive recordings when it reaches a trusted
network, retain more RecentClips, expose a local viewer, and provide guarded
filesystem and gadget recovery.

This community video provides a useful introduction to the original TeslaUSB
architecture and installation flow. Its setup details may not match TeslaUSB
Enhanced; follow the current quick start above:

[![TeslaUSB introduction and installation](https://img.youtube.com/vi/ETs6r1vKTO8/0.jpg)](https://www.youtube.com/watch?v=ETs6r1vKTO8 "TeslaUSB introduction and installation")

The project traces back to
[this Reddit thread](https://www.reddit.com/r/teslamotors/comments/9m9gyk/build_a_smart_usb_drive_for_your_tesla_dash_cam/)
and the community-maintained upstream repository.

## Contributing

Pull requests and issue reports are welcome. Keep changes focused, preserve the
security and fail-closed boundaries, and include relevant tests or exact
reproduction steps. Never commit real TeslaUSB configuration files, passwords,
tokens, private keys, VINs, or archive credentials.

## License and names

This derivative is distributed under the included [MIT license](LICENSE). It
is an independent, unofficial project and is not endorsed by or affiliated
with Tesla, Inc., Raspberry Pi Ltd., or the upstream TeslaUSB maintainers.
Product and project names belong to their respective owners.
