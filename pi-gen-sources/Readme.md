### Downloading a verified TeslaUSB image — version 2.0.0

Image releases include an arm64 Raspberry Pi OS Lite (Debian Trixie) `.img.xz`
for Raspberry Pi Zero 2 W, its SHA-256 file, a machine-readable provenance
record, and the installed package list. Download both the compressed image and
checksum from the same GitHub release, run the appropriate local SHA-256
verification command, then select the `.img.xz` directly with Raspberry Pi
Imager's **Use custom** option. Do not apply Imager OS customization; use the
offline wizard placed on the flashed boot partition instead.

The release workflow builds on a native arm64 runner, verifies the image through
read-only FAT/ext4 mounts, confirms Trixie/arm64/Zero 2 W boot artifacts, checks
the locked image account and absence of active configuration or generated
device identity, validates the embedded source manifest, tests the compressed
stream, and uploads only checked assets to the matching unpublished draft.
FFmpeg is bundled in version 2.0.0, and its installed tools and JPEG encoder are
verified for first-frame recording cards and the lightweight six-camera overview.

Both a `VERSION` push and a manual tag build leave the release in draft state.
Manual builds use the `main-dev` workflow and validated `main-dev` source; a
successful build does not publish the release. The job summary records the
source commit and compressed image SHA-256 for handoff to hardware testing.

An authorized tester downloads the draft's four matching assets while signed in,
checks the compressed image hash, and flashes a spare card. Record fresh setup,
vehicle USB recognition, new daily and Sentry recordings, completed snapshots,
archiving, downloads, and recovery results against that exact image. Only then
publish it deliberately, after rechecking the tag/source and all asset digests.
Do not rebuild or replace the accepted image; a changed image needs another test.
Version 2.0.0 remains an unpublished draft until this acceptance is complete.
Earlier release tags and embedded build identifiers remain intact for provenance.

Source export and manifest generation are deterministic. The full filesystem
image is not claimed to be bit-for-bit reproducible because Debian and Raspberry
Pi package repositories are not snapshot-pinned; the provenance and package
assets record what was actually built.

### Building a TeslaUSB image manually

These instructions reproduce the supported source recipe when a release does
not contain an image or when an operator wants an independent build.

1. Start from a clean Git clone of the TeslaUSB release tag. GitHub-generated
   source archives do not contain the Git metadata needed to prove the exact
   source commit and are intentionally rejected by `prepare.sh`:

   ```bash
   git clone --branch <release-tag> --single-branch https://github.com/jakubgt/teslausb-enhanced.git teslausb
   ```

   Public repository clones need no authentication. If building from a private
   mirror, substitute its URL and authenticate locally; never put a token in
   the URL, committed configuration, build recipe, or release notes.

2. Clone pi-gen's 64-bit `arm64` branch and detach at the commit pinned by this
   release:

   ```bash
   git clone --branch arm64 https://github.com/RPi-Distro/pi-gen.git
   cd pi-gen
   git checkout --detach ca8aeed0ae300c2a89f55ce9617d5f96a27e99e5
   git rev-parse HEAD
   ```

   The final command must print
   `ca8aeed0ae300c2a89f55ce9617d5f96a27e99e5`.

3. Follow pi-gen's documentation to install its build dependencies.

4. From the root of the pi-gen checkout, run the TeslaUSB preparation script:

   ```bash
   /path/to/teslausb/pi-gen-sources/prepare.sh
   ```

   Preparation refuses modified, staged, or deleted tracked TeslaUSB files. It
   exports only committed files from a fixed allowlist, rebuilds
   `stage_teslausb` from scratch, and therefore cannot retain stale files or
   copy ignored/untracked credentials from the working tree. Any local edits
   inside pi-gen's generated `stage_teslausb` directory are discarded on the
   next preparation.

5. If necessary, adjust `ROOT_MARGIN` or `ROOT_PART_SIZE` in
   `export-image/prerun.sh`, then run `./build.sh` or `./build-docker.sh` as
   documented by pi-gen. The Docker build is recommended. The finished image
   will be placed in pi-gen's `deploy` directory.

The image embeds the committed TeslaUSB runtime source under
`/usr/local/share/teslausb-source`. It includes the MIT `LICENSE`,
`SOURCE-METADATA`, and `SOURCE-MANIFEST.sha256`. The metadata records the exact
TeslaUSB commit, version, reproducible source timestamp, pi-gen commit, and
manifest digest. You can verify the installed source later with:

```bash
cd /usr/local/share/teslausb-source
sha256sum -c SOURCE-MANIFEST.sha256
```

#### Deliberately using another pi-gen commit

The supported release pin is safest. For controlled testing of a reviewed
pi-gen fork or newer commit, the preparation script accepts only an explicit
full commit pin; it never accepts a floating branch:

```bash
TESLAUSB_PI_GEN_COMMIT_OVERRIDE=<lowercase-40-character-commit-sha> \
  /path/to/teslausb/pi-gen-sources/prepare.sh
```

The checkout's `HEAD` must exactly equal that SHA, and both the selected commit
and the official release pin are recorded in `SOURCE-METADATA`. An override is
not the supported release image recipe and should be tested independently.

The resulting arm64 image supports Raspberry Pi Zero 2 W. Do not attempt to
turn an existing 32-bit or Bookworm installation into this image with an APT
distribution upgrade; flash the new image and restore the TeslaUSB
configuration instead. Keep real credentials in the boot configuration and
never in the checkout used to build the image.

pi-gen requires a configured first-user password when its first-boot rename is
disabled. The TeslaUSB customization stage locks that account directly in the
offline image before the image can boot or SSH can start. The first-boot script
changes or unlocks it only when `SSH_USER_PASSWORD` or the explicitly insecure
`SSH_ALLOW_DEFAULT_PASSWORD=true` option requests that.

`TIME_ZONE="auto"` uses the exact
[tzupdate revision `2d41763825fcfae3f2266bf1628ce245ab285f5a`](https://github.com/marcone/tzupdate/commit/2d41763825fcfae3f2266bf1628ce245ab285f5a).
Setup downloads it into a root-private temporary directory and requires SHA-256
`7e6769fcf6c2a19a3492a9d62bd529714081132b12244796a4800269804857cb` before
execution. An integrity mismatch stops setup.
