# Security and privacy reporting

Do not publish credentials, exploit details, or sensitive diagnostic attachments
in an issue or pull request. Public content may be copied before it is removed.

## Report a suspected vulnerability privately

If this repository's GitHub **Security** tab offers **Report a vulnerability**,
use that private reporting flow. Its availability depends on repository settings;
this document does not assert that it is enabled.

If no private reporting option is offered, ask the maintainer for a private
channel without including vulnerability details or sensitive attachments. Wait
for an agreed channel before sending a minimal, sanitized reproduction. Never
send real passwords, tokens, private keys, or complete device/card images.

## Before sharing a normal bug report

Review a local copy of diagnostics, logs, screenshots, and configuration excerpts.
Remove passwords, tokens, keys, VINs, Wi-Fi SSIDs, private IP addresses, personal
paths, account names, archive-server details, and identifying recording content.
Automatic credential redaction does not make a report anonymous. Share only the
small excerpt needed to explain the problem; never attach real setup files or
raw diagnostic bundles without reviewing and sanitizing their contents.

If a credential was exposed, revoke or rotate it first. Deleting a comment or
rewriting repository history does not invalidate copied credentials. Ask the
maintainer to help remove the exposed material through a private channel; do
not repost it in a public cleanup request.

Keep the TeslaUSB HTTP dashboard on a trusted private LAN or VPN. Web
authentication is not transport encryption, and public source availability does
not make the device's dashboard suitable for Internet exposure.
