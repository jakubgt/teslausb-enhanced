# Declarative setup configuration

New TeslaUSB images use `teslausb_setup.json` as the preferred first-boot configuration. JSON values are validated against a strict allowlist and loaded without sourcing or evaluating the file as shell code. The legacy `teslausb_setup_variables.conf` format remains available for compatibility but is deprecated.

For a fresh image, open `teslausb_config_wizard.html` from the card's boot partition. It is a self-contained offline page with no network calls, remote scripts, analytics, form submission, or browser storage. It creates a new file in the browser download folder; it never scans for a card or writes to a disk automatically. Copy the download to the boot partition with the exact filename `teslausb_setup.json`.

## File format

Copy `teslausb_setup.json.sample` from the boot partition to `teslausb_setup.json`, then replace every sample placeholder before first boot. A minimal local-only configuration looks like this:

```json
{
  "schema_version": 1,
  "variables": {
    "SSID": "Garage WiFi",
    "WIFIPASS": "replace-with-your-password",
    "WIFI_COUNTRY": "US",
    "ARCHIVE_SYSTEM": "none",
    "CAM_SIZE": "40G",
    "WEB_USERNAME": "viewer",
    "WEB_PASSWORD": "replace-with-a-unique-long-password"
  }
}
```

JSON does not support comments. Keep the deprecated `teslausb_setup_variables.conf.sample` beside your private JSON file as a reference for optional-setting names and descriptions; express the selected values with the JSON types below.

`WIFI_COUNTRY` is the uppercase ISO 3166-1 alpha-2 regulatory country for the Pi's physical location (`GB`, not `UK`, for the United Kingdom). New images refuse to enable Wi-Fi without a recognized code rather than guessing a country. Older configurations that omit the field remain loadable for upgrade compatibility, but validation warns and a clean first boot cannot connect until it is added.

The validator requires native JSON types:

- Feature switches such as `SAMBA_ENABLED` are booleans (`true` or `false`), not quoted strings.
- Timeouts, retry counts, and similar numeric values are integers.
- `INSTALL_USER_REQUESTED_PACKAGES` and `RCLONE_FLAGS` are arrays of strings.
- Sizes such as `CAM_SIZE` remain strings such as `"40G"`.

Unknown variables, duplicate JSON keys, wrong types, unsafe ranges, control characters, sample placeholders, invalid configuration pairs, and archive-specific missing values stop setup before the configuration is loaded. Access-point addresses must be IPv4 and end in `.1` through `.9` because `.10` through `.254` is the DHCP pool. Trigger values are filenames rather than paths, and timezone names cannot traverse outside `/usr/share/zoneinfo`.

The wizard's recommended Zero 2 W profile starts with a 40 GB camera image, `ARCHIVE_SYSTEM: "none"`, `ARCHIVE_RECENTCLIPS: false`, `TEMPERATURE_POSTARCHIVE: true`, a named timezone, and web authentication using a locally generated password. It leaves `DATA_DRIVE`, access-point mode, guest Samba, notifications, and third-party WebUI downloads unset. These defaults minimize destructive or externally dependent first-boot behavior; add an archive after confirming the local system works.

Values are transferred with a NUL-delimited internal format and are never sourced as commands. `NOTIFICATION_COMMAND_START` and `NOTIFICATION_COMMAND_FINISH` are the one explicit opt-in exception: when `NOTIFICATION_COMMAND_ENABLED=true`, those command strings are intentionally executed later by the notification service. Leave that feature disabled unless you have reviewed the commands as root-owned code.

## Migrate a legacy configuration

From a local checkout with Node.js installed, convert a literal legacy file with:

```console
node tools/teslausb-config.js migrate teslausb_setup_variables.conf teslausb_setup.json
```

Migration first applies the legacy preflight checks, accepts only literal assignments and arrays, converts known booleans and integers to native JSON types, enforces the same integer ranges and field relationships as the runtime validator, rejects unsupported variable names, and never overwrites an existing destination. Review the result against `teslausb_setup.json.sample` before using it.

On an existing installation, upgrade TeslaUSB while the legacy configuration is still in place, confirm the upgrade completed, and only then replace the legacy file with the migrated JSON file. Older installations do not have the declarative loader needed to read JSON.

## Secret handling

Both configuration formats can contain Wi-Fi passwords, archive credentials, API tokens, and private SSH material. Keep the file off shared storage, never commit it, and retain only an encrypted/private backup. The wizard redacts secrets in its on-screen review, but the downloaded JSON necessarily contains them. Close the wizard tab after copying the file and clear the download from shared computers. On the Pi, TeslaUSB refuses a JSON configuration that is not owned by `root:root`, normalizes a root-owned file to mode `0600` when possible, and copies the boot configuration into root-only storage before loading it. The BLE web dispatcher reads only the validated VIN it needs rather than sourcing the full configuration.

The JSON format prevents configuration text from becoming shell code; it does not make the secrets themselves public-safe. Rotate credentials if the SD card or a configuration copy may have been exposed.
