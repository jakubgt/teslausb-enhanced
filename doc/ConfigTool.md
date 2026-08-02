# Local configuration helper

`tools/teslausb-config.js` is an optional, dependency-free Node.js tool for preparing `teslausb_setup_variables.conf` on your own computer. It never sources the configuration file: preflight treats it as text, so unexpected shell expressions are reported instead of executed.

The normal sample-file workflow remains supported. This helper is useful when passwords contain quotes or backslashes, when you want a repeatable minimal configuration, or when you need to share a redacted copy for support.

## Generate a minimal configuration

Create a private file named `teslausb-config-values.json` containing the variables you need. For example, a Pi that initially stores recordings locally could use:

```json
{
  "SSID": "Garage WiFi",
  "WIFIPASS": "replace this",
  "ARCHIVE_SYSTEM": "none",
  "CAM_SIZE": "40G",
  "WEB_USERNAME": "viewer",
  "WEB_PASSWORD": "replace this too"
}
```

Generate the setup file:

```console
node tools/teslausb-config.js generate teslausb-config-values.json teslausb_setup_variables.conf
```

The generator quotes literal values using Bash ANSI-C quoting, including apostrophes, backslashes, spaces, and dollar signs. It refuses to overwrite an existing output file. Both the JSON input and generated configuration contain secrets; keep them private, delete unneeded copies, and never commit them.

For CIFS, NFS, rsync, or rclone, use the variable names and requirements documented in `teslausb_setup_variables.conf.sample`. Generator input may also use a top-level `variables` object.

## Preflight an edited file

```console
node tools/teslausb-config.js preflight teslausb_setup_variables.conf
```

Preflight checks exact literal export syntax, common sample placeholders, archive-specific required values, size formats, Wi-Fi/access-point and web-auth pairs, safe hostname syntax, pinned external-WebUI metadata, and potentially destructive `DATA_DRIVE` use. Web passwords must be 12–72 UTF-8 bytes for bcrypt and must not be a known default or match the username. Warnings are advisory; errors return a nonzero exit code. A successful preflight cannot verify that Wi-Fi credentials, servers, shares, paths, checksums, or passwords are correct, so retain the original sample comments and check those values carefully.

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
