# Local configuration helper

`teslausb_config_wizard.html` is the recommended helper for new images. Open the copy on the flashed card's boot partition in any modern browser, complete the offline form, then copy its downloaded `teslausb_setup.json` back to the boot partition. It includes conservative Raspberry Pi Zero 2 W recommendations and generates a unique web password with the browser's cryptographic random-number generator. It does not contact a server or write directly to a disk.

`tools/teslausb-config.js` is an optional, dependency-free Node.js tool for checking and migrating existing TeslaUSB configuration on your own computer. New images prefer the strict [declarative JSON format](DeclarativeConfig.md). The helper never sources a legacy configuration file: preflight and migration treat it as text, so unexpected shell expressions are reported instead of executed.

The legacy sample-file workflow remains supported during the deprecation period. This helper is useful when passwords contain quotes or backslashes, when migrating an existing installation, or when you need to share a redacted copy for support.

## Migrate to the preferred JSON format

```console
node tools/teslausb-config.js migrate teslausb_setup_variables.conf teslausb_setup.json
```

Migration accepts only safe literal assignments, validates the old configuration first, converts known booleans, integers, and arrays to native JSON types, enforces runtime integer ranges and cross-field requirements, and refuses unknown variable names or an existing output file. Review the generated file against `teslausb_setup.json.sample`. The generated file contains secrets and must remain private.

For an existing Pi, install the release containing JSON support before switching formats: upgrade with the legacy `.conf`, confirm the upgrade, migrate the file locally, and then install the reviewed JSON file as `/root/teslausb_setup.json` with owner `root:root` and mode `0600`.

## Generate a legacy configuration

Create a private file named `teslausb-config-values.json` containing the variables you need. For example, a Pi that initially stores recordings locally could use:

```json
{
  "SSID": "Garage WiFi",
  "WIFIPASS": "replace this",
  "WIFI_COUNTRY": "US",
  "ARCHIVE_SYSTEM": "none",
  "CAM_SIZE": "40G",
  "WEB_USERNAME": "viewer",
  "WEB_PASSWORD": "replace this too"
}
```

Generate the legacy setup file:

```console
node tools/teslausb-config.js generate teslausb-config-values.json teslausb_setup_variables.conf
```

The generator quotes literal values using Bash ANSI-C quoting, including apostrophes, backslashes, spaces, and dollar signs. It refuses to overwrite an existing output file. Both the JSON input and generated configuration contain secrets; keep them private, delete unneeded copies, and never commit them.

For CIFS, NFS, rsync, or rclone, use the variable names and requirements documented in `teslausb_setup_variables.conf.sample`. Generator input may also use a top-level `variables` object.

## Preflight an edited file

```console
node tools/teslausb-config.js preflight teslausb_setup_variables.conf
```

Preflight checks exact literal export syntax, common sample placeholders, archive-specific required values, integer ranges, size formats, Wi-Fi/access-point and web-auth pairs, the recognized uppercase ISO 3166-1 alpha-2 Wi-Fi regulatory country, enabled-notification dependencies, safe hostname/path syntax, pinned external-WebUI metadata, and potentially destructive `DATA_DRIVE` use. Web passwords must be 12–72 UTF-8 bytes for bcrypt and must not be a known default or match the username. Warnings are advisory; errors return a nonzero exit code. A successful preflight can recognize the country code but cannot verify that it matches the Pi's physical location, or that Wi-Fi credentials, servers, shares, paths, checksums, or passwords are correct, so retain the original sample comments and check those values carefully.

Dynamic shell expressions, token concatenation, and mixed quoted/unquoted values are intentionally rejected. If you rely on advanced shell syntax, keep using the documented manual workflow and review the file yourself.

## Optional pinned external WebUI

The bundled interface at `/` works without a download. Leave both `WEBUI_RELEASE` and `WEBUI_SHA256` absent for an offline-safe install. To install the separately released interface at `/new/`, set both variables to an explicit immutable release and the SHA-256 of that release asset:

```json
{
  "WEBUI_RELEASE": "v1.2.1",
  "WEBUI_SHA256": "replace-with-the-release-asset-sha256"
}
```

`latest`, a release without a checksum, and a checksum without a release all fail preflight. Obtain the digest from a trusted release source and compare it before adding it to the private values file.

## Create a sanitized support copy

```console
node tools/teslausb-config.js sanitize teslausb_setup_variables.conf teslausb_setup_variables.sanitized.conf
```

The sanitized copy comments out recognized credentials, tokens, URLs, host/share identifiers, allowed web hostnames, VINs, SSH keys, and notification commands. It is intended for review or a support request and is deliberately not installable. Inspect it before sharing because free-form comments or uncommon custom variable names can still contain private information.

Keep a separate encrypted/private backup of the original if you need a restorable copy. The tool never overwrites an existing generated or sanitized file.
