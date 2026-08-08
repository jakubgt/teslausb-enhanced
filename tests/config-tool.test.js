"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {spawnSync} = require("node:child_process");
const {
  bashQuote,
  decodeLiteral,
  generateConfig,
  migrateConfig,
  parseConfig,
  preflightConfig,
  sanitizeConfig
} = require("../tools/teslausb-config.js");

const secret = "spaces ' quotes \\ and $dollars";
assert.equal(decodeLiteral(bashQuote(secret)), secret);
const secretWithCommentText = "apostrophe ' followed by # hash";
assert.equal(decodeLiteral(`${bashQuote(secretWithCommentText)} # safe comment`), secretWithCommentText);

const generated = generateConfig({
  SSID: "Garage WiFi",
  WIFIPASS: secret,
  ARCHIVE_SYSTEM: "cifs",
  ARCHIVE_SERVER: "nas.local",
  SHARE_NAME: "Tesla/Clips",
  SHARE_USER: "tesla",
  SHARE_PASSWORD: "share secret",
  CAM_SIZE: "40G",
  WEB_USERNAME: "viewer",
  WEB_PASSWORD: "a long web secret"
});
const parsed = parseConfig(generated);
assert.equal(parsed.assignments.get("WIFIPASS").value, secret);
assert.equal(parsed.assignments.get("ARCHIVE_SYSTEM").value, "cifs");
assert.equal(preflightConfig(generated).issues.filter((issue) => issue.level === "error").length, 0);

const partialAuth = generated.replace(/export WEB_PASSWORD=.*\n/, "");
assert.match(
  preflightConfig(partialAuth).issues.map((issue) => issue.message).join("\n"),
  /WEB_USERNAME and WEB_PASSWORD/
);

const unsafeWebPassword = generated.replace(
  /export WEB_PASSWORD=.*\n/,
  () => "export WEB_PASSWORD=$'raspberry'\n");
assert.match(
  preflightConfig(unsafeWebPassword).issues.map((issue) => issue.message).join("\n"),
  /unsafe default/
);

const incompleteWebUiPin = `${generated}export WEBUI_RELEASE=$'v1.2.1'\n`;
assert.match(
  preflightConfig(incompleteWebUiPin).issues.map((issue) => issue.message).join("\n"),
  /WEBUI_RELEASE and WEBUI_SHA256/
);
const completeWebUiPin = `${incompleteWebUiPin}export WEBUI_SHA256=$'${"a".repeat(64)}'\n`;
assert.equal(
  preflightConfig(completeWebUiPin).issues.filter((issue) => issue.level === "error").length,
  0
);
const floatingWebUiPin = completeWebUiPin.replace(
  /export WEBUI_RELEASE=.*\n/,
  () => "export WEBUI_RELEASE=$'latest'\n");
assert.match(
  preflightConfig(floatingWebUiPin).issues.map((issue) => issue.message).join("\n"),
  /immutable release/
);

const invalidHostname = `${generated}export TESLAUSB_HOSTNAME=$'garage.pi'\n`;
assert.match(
  preflightConfig(invalidHostname).issues.map((issue) => issue.message).join("\n"),
  /one DNS label/
);
const validHostname = `${generated}export TESLAUSB_HOSTNAME=$'teslausb-garage2'\n`;
assert.equal(
  preflightConfig(validHostname).issues.filter((issue) => issue.level === "error").length,
  0
);
const conflictingWebAuth = `${generated}export WEB_AUTH_DISABLED=$'true'\n`;
assert.match(
  preflightConfig(conflictingWebAuth).issues.map((issue) => issue.message).join("\n"),
  /cannot be combined/
);
const invalidBleVin = `${generated}export TESLA_BLE_VIN=$'not-a-vin'\nexport SENTRY_CASE=$'1'\n`;
assert.match(
  preflightConfig(invalidBleVin).issues.map((issue) => issue.message).join("\n"),
  /17-character VIN/
);

const unsafeApIp = `${generated}export AP_IP=$'192.168.66.1/e touch /tmp/owned'\n`;
assert.match(
  preflightConfig(unsafeApIp).issues.map((issue) => issue.message).join("\n"),
  /AP_IP must be an IPv4 address/
);
const unsafeTrigger = `${generated}export TRIGGER_FILE_SAVED=$'..\/..\/outside'\n`;
assert.match(
  preflightConfig(unsafeTrigger).issues.map((issue) => issue.message).join("\n"),
  /must be one filename/
);
const unsafeTimeZone = `${generated}export TIME_ZONE=$'..\/..\/etc\/passwd'\n`;
assert.match(
  preflightConfig(unsafeTimeZone).issues.map((issue) => issue.message).join("\n"),
  /without traversal/
);
for (const dataDrive of [
  "/dev/sda",
  "/dev/mmcblk0",
  "/dev/nvme0n1",
  "/dev/disk/by-id/usb-SanDisk_Ultra_Fit-0:0"
]) {
  const config = `${generated}export DATA_DRIVE=${bashQuote(dataDrive)}\n`;
  assert.equal(
    preflightConfig(config).issues.filter((issue) => issue.level === "error").length,
    0,
    `valid DATA_DRIVE was rejected: ${dataDrive}`
  );
}
for (const dataDrive of [
  "/dev/../sda",
  "/dev/sda/../sdb",
  "/dev/disk/./by-id/device",
  "/dev//sda",
  "/dev/sda/",
  "/dev/.hidden",
  "/tmp/sda"
]) {
  const config = `${generated}export DATA_DRIVE=${bashQuote(dataDrive)}\n`;
  assert.match(
    preflightConfig(config).issues.map((issue) => issue.message).join("\n"),
    /without traversal/,
    `unsafe DATA_DRIVE was accepted: ${dataDrive}`
  );
}
const missingPushoverValues = `${generated}export PUSHOVER_ENABLED=$'true'\n`;
assert.match(
  preflightConfig(missingPushoverValues).issues.map((issue) => issue.message).join("\n"),
  /PUSHOVER_USER_KEY is required/
);
const missingNotificationCommand = `${generated}export NOTIFICATION_COMMAND_ENABLED=$'true'\n`;
assert.match(
  preflightConfig(missingNotificationCommand).issues.map((issue) => issue.message).join("\n"),
  /NOTIFICATION_COMMAND_START or NOTIFICATION_COMMAND_FINISH/
);
const placeholderSlack = `${generated}export SLACK_ENABLED=$'true'\nexport SLACK_WEBHOOK_URL=$'http:\/\/domain\/path\/'\n`;
assert.match(
  preflightConfig(placeholderSlack).issues.map((issue) => issue.message).join("\n"),
  /sample placeholder/
);

const validAllowedHosts = `${generated}export WEB_ALLOWED_HOSTS=$'garage.example.ts.net, 192.168.7.2 [fd00::12]'\n`;
assert.equal(
  preflightConfig(validAllowedHosts).issues.filter((issue) => issue.level === "error").length,
  0
);
const hostWithPort = `${generated}export WEB_ALLOWED_HOSTS=$'garage.example.ts.net:8443'\n`;
assert.match(
  preflightConfig(hostWithPort).issues.map((issue) => issue.message).join("\n"),
  /without ports/
);

const oversizedWebPassword = generated.replace(
  /export WEB_PASSWORD=.*\n/,
  () => `export WEB_PASSWORD=${bashQuote("é".repeat(37))}\n`);
assert.match(
  preflightConfig(oversizedWebPassword).issues.map((issue) => issue.message).join("\n"),
  /12 and 72 UTF-8 bytes/
);

const missingSambaPassword = `${generated}export SAMBA_ENABLED=$'true'\n`;
assert.match(
  preflightConfig(missingSambaPassword).issues.map((issue) => issue.message).join("\n"),
  /SAMBA_PASSWORD is required/
);

const malicious = `${generated}export EXTRA=$(touch should-never-exist)\n`;
assert.match(
  preflightConfig(malicious).issues.map((issue) => issue.message).join("\n"),
  /shell expressions are not accepted/
);
const maliciousAnsiConcatenation = `${generated}export EXTRA=$'safe'$(touch /tmp/pwn)$'tail'\n`;
assert.match(
  preflightConfig(maliciousAnsiConcatenation).issues.map((issue) => issue.message).join("\n"),
  /ANSI-C quoted value must be one literal token/
);
const maliciousDoubleQuotedConcatenation = `${generated}export EXTRA="safe"; touch /tmp/pwn; echo "tail"\n`;
assert.match(
  preflightConfig(maliciousDoubleQuotedConcatenation).issues.map((issue) => issue.message).join("\n"),
  /double-quoted value must be one literal token/
);

const maliciousArray = `${generated}export RCLONE_FLAGS=(ok; touch /tmp/owned)\n`;
assert.match(
  preflightConfig(maliciousArray).issues.map((issue) => issue.message).join("\n"),
  /array contains a shell expression/
);
const literalArray = `${generated}export RCLONE_FLAGS=($'--header' $'value with spaces')\n`;
assert.equal(
  preflightConfig(literalArray).issues.filter((issue) => issue.level === "error").length,
  0
);
const migrated = JSON.parse(migrateConfig(
  `${literalArray}export SAMBA_ENABLED=$'false'\n` +
  "export GOTIFY_ENABLED=$'false'\n" +
  "export NTFY_ENABLED=$'true'\n" +
  "export NTFY_URL=$'https://ntfy.example.test/teslausb'\n" +
  "export ARCHIVE_DELAY=$'45'\n" +
  "export INSTALL_USER_REQUESTED_PACKAGES=$'jq curl'\n"
));
assert.equal(migrated.schema_version, 1);
assert.equal(migrated.variables.SAMBA_ENABLED, false);
assert.equal(migrated.variables.GOTIFY_ENABLED, false);
assert.equal(migrated.variables.NTFY_ENABLED, true);
assert.equal(migrated.variables.ARCHIVE_DELAY, 45);
assert.deepEqual(migrated.variables.RCLONE_FLAGS, ["--header", "value with spaces"]);
assert.deepEqual(migrated.variables.INSTALL_USER_REQUESTED_PACKAGES, ["jq", "curl"]);
assert.throws(
  () => migrateConfig(`${generated}export ARCHIVE_DELAY=$'-1'\n`),
  /between 0 and 86400/
);
assert.throws(
  () => migrateConfig(`${generated}export RCLONE_FLAGS=($'--header' $'bad\\nvalue')\n`),
  /control character/
);
assert.throws(
  () => migrateConfig(`${generated}export INSTALL_USER_REQUESTED_PACKAGES=$'jq --option'\n`),
  /unsupported package name/
);
assert.throws(
  () => migrateConfig(`${generated}export BASH_ENV=$'/tmp/owned'\n`),
  /Unsupported variable/
);
assert.throws(
  () => migrateConfig(`${generated}export BRANCH=$(touch should-never-exist)\n`),
  /failed preflight/
);
const quotedArray = generateConfig({
  SSID: "Garage WiFi",
  WIFIPASS: "wifi secret",
  ARCHIVE_SYSTEM: "none",
  CAM_SIZE: "40G",
  RCLONE_FLAGS: ["header: O'Reilly #tag", "--fast-list"]
});
assert.equal(
  preflightConfig(quotedArray).issues.filter((issue) => issue.level === "error").length,
  0
);
assert.throws(
  () => generateConfig({ARCHIVE_SYSTEM: "none", CAM_SIZE: "40G", RCLONE_FLAGS: [{flag: true}]}),
  /array values must be strings, numbers, or booleans/
);

const sanitized = sanitizeConfig(`${generated}export AP_SSID=$'Road network'\nexport WEB_ALLOWED_HOSTS=$'private.tailnet-name.ts.net'\n`);
for (const leaked of ["Garage WiFi", "Road network", secret, "nas.local", "share secret", "a long web secret", "private.tailnet-name.ts.net"]) {
  assert.equal(sanitized.includes(leaked), false, `sanitized output leaked ${leaked}`);
}
assert.match(sanitized, /export ARCHIVE_SYSTEM=\$'cifs'/);
assert.match(sanitized, /SANITIZED: export WIFIPASS=\$'<redacted>'/);

const testDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "teslausb-config-test-"));
try {
  const tool = path.join(__dirname, "..", "tools", "teslausb-config.js");
  const valuesPath = path.join(testDirectory, "values.json");
  const configPath = path.join(testDirectory, "teslausb_setup_variables.conf");
  const declarativePath = path.join(testDirectory, "teslausb_setup.json");
  const backupPath = path.join(testDirectory, "teslausb_setup_variables.sanitized.conf");
  fs.writeFileSync(valuesPath, JSON.stringify({
    SSID: "Garage WiFi",
    WIFIPASS: "wifi secret",
    ARCHIVE_SYSTEM: "none",
    CAM_SIZE: "40G"
  }));

  let result = spawnSync(process.execPath, [tool, "generate", valuesPath, configPath], {encoding: "utf8"});
  assert.equal(result.status, 0, result.stderr);
  if (process.platform !== "win32") {
    assert.equal(fs.statSync(configPath).mode & 0o777, 0o600);
  }

  result = spawnSync(process.execPath, [tool, "preflight", configPath], {encoding: "utf8"});
  assert.equal(result.status, 0, result.stdout + result.stderr);

  result = spawnSync(process.execPath, [tool, "migrate", configPath, declarativePath], {encoding: "utf8"});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(fs.readFileSync(declarativePath, "utf8")).schema_version, 1);
  if (process.platform !== "win32") {
    assert.equal(fs.statSync(declarativePath).mode & 0o777, 0o600);
  }

  result = spawnSync(process.execPath, [tool, "migrate", configPath, declarativePath], {encoding: "utf8"});
  assert.notEqual(result.status, 0, "migrate unexpectedly overwrote an existing JSON configuration");

  result = spawnSync(process.execPath, [tool, "sanitize", configPath, backupPath], {encoding: "utf8"});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(backupPath, "utf8").includes("wifi secret"), false);

  result = spawnSync(process.execPath, [tool, "sanitize", configPath, backupPath], {encoding: "utf8"});
  assert.notEqual(result.status, 0, "sanitize unexpectedly overwrote an existing backup");
} finally {
  fs.rmSync(testDirectory, {recursive: true, force: true});
}

console.log("config tool tests passed");
