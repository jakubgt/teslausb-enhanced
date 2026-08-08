"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const {spawnSync} = require("node:child_process");

const repoRoot = path.resolve(__dirname, "..");
const wizardPath = path.join(
  repoRoot,
  "pi-gen-sources",
  "00-teslausb-tweaks",
  "files",
  "teslausb_config_wizard.html"
);
const validatorPath = path.join(
  repoRoot,
  "pi-gen-sources",
  "00-teslausb-tweaks",
  "files",
  "teslausb_config.py"
);
const countryCodesPath = path.join(
  repoRoot,
  "pi-gen-sources",
  "00-teslausb-tweaks",
  "files",
  "iso3166-country-codes.json"
);
const stageScriptPath = path.join(
  repoRoot,
  "pi-gen-sources",
  "00-teslausb-tweaks",
  "00-run.sh"
);

const html = fs.readFileSync(wizardPath, "utf8");
const scriptMatches = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
const styleMatches = [...html.matchAll(/<style>([\s\S]*?)<\/style>/g)];
assert.equal(scriptMatches.length, 1, "wizard must have exactly one self-contained script");
assert.equal(styleMatches.length, 1, "wizard must have exactly one self-contained stylesheet");
const script = scriptMatches[0][1];
const style = styleMatches[0][1];

function sha256Base64(value) {
  return crypto.createHash("sha256").update(value, "utf8").digest("base64");
}

const cspMatch = html.match(/<meta http-equiv="Content-Security-Policy" content="([^"]+)">/);
assert.ok(cspMatch, "wizard is missing its Content Security Policy");
const csp = cspMatch[1];
for (const directive of [
  "default-src 'none'",
  "connect-src 'none'",
  "frame-src 'none'",
  "object-src 'none'",
  "form-action 'none'",
  "base-uri 'none'",
  "worker-src 'none'"
]) {
  assert.ok(csp.includes(directive), `CSP is missing ${directive}`);
}
assert.ok(csp.includes(`script-src 'sha256-${sha256Base64(script)}'`), "inline script hash does not match CSP");
assert.ok(csp.includes(`style-src 'sha256-${sha256Base64(style)}'`), "inline style hash does not match CSP");
assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|https?:|data:|blob:/i);

assert.doesNotMatch(html, /https?:\/\//i, "offline wizard contains a remote URL");
assert.doesNotMatch(html, /\son[a-z]+\s*=/i, "wizard contains an inline event handler");
const countrySelect = html.match(/<select id="wifiCountry"[^>]*>/);
assert.ok(countrySelect, "wizard is missing the required Wi-Fi country selector");
assert.match(countrySelect[0], /\srequired(?:\s|>)/i);
assert.match(html, /<option value="" selected>/i, "country selector must start with an empty choice");
assert.doesNotMatch(html, /<option value="[A-Z]{2}" selected>/i, "wizard must not guess the user's regulatory country");
assert.doesNotMatch(
  script,
  /\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon|localStorage|sessionStorage|indexedDB|serviceWorker)\b/,
  "wizard contains a network or persistent-storage API"
);
assert.match(script, /crypto\.getRandomValues\(/, "password generator does not use Web Crypto");
assert.doesNotMatch(script, /Math\.random\(/, "password generator uses Math.random");
const downloadNames = [...script.matchAll(/\.download\s*=\s*"([^"]+)"/g)].map((match) => match[1]);
assert.deepEqual(downloadNames, ["teslausb_setup.json"]);
assert.equal((script.match(/\.download\s*=/g) || []).length, downloadNames.length, "download name is not a fixed literal");

const sandbox = {
  Blob,
  Error,
  Intl,
  JSON,
  Math,
  Number,
  Object,
  Set,
  String,
  TextEncoder,
  Uint8Array,
  crypto: crypto.webcrypto
};
vm.createContext(sandbox);
vm.runInContext(script, sandbox, {filename: wizardPath});
const wizard = sandbox.TeslaUsbConfigWizard;
assert.ok(wizard, "wizard did not export its testable configuration model");
const countryCodesDocument = JSON.parse(fs.readFileSync(countryCodesPath, "utf8"));
assert.deepEqual([...wizard.countryCodes], countryCodesDocument.codes);
assert.equal(wizard.countryCodes.includes("US"), true);
assert.equal(wizard.countryCodes.includes("DE"), true);
assert.equal(wizard.countryCodes.includes("UK"), false);
assert.equal(wizard.countryCodes.includes("ZZ"), false);

const generatedPasswords = new Set();
for (let index = 0; index < 24; index += 1) {
  const password = wizard.generatePassword();
  assert.equal(password.length, 28);
  assert.match(password, /[A-Z]/);
  assert.match(password, /[a-z]/);
  assert.match(password, /[0-9]/);
  assert.match(password, /[^A-Za-z0-9]/);
  generatedPasswords.add(password);
}
assert.equal(generatedPasswords.size, 24, "password generator repeated a value during its basic test");

const baseValues = {
  wifiCountry: "US",
  ssid: "Garage 2.4 GHz",
  wifiPassword: "private wifi password",
  camSize: "40G",
  timeZone: "America/Chicago",
  archiveSystem: "none",
  cifsServer: "",
  cifsShare: "",
  cifsUser: "",
  cifsPassword: "",
  nfsServer: "",
  nfsShare: "",
  rsyncUser: "",
  rsyncServer: "",
  rsyncPath: "",
  rcloneDrive: "",
  rclonePath: "",
  webUsername: "teslausb",
  webPassword: "correct horse battery staple",
  sshPublicKey: "",
  temperatureEnabled: true
};

const profileInputs = [
  {...baseValues, archiveSystem: "none"},
  {
    ...baseValues,
    archiveSystem: "cifs",
    cifsServer: "nas.local",
    cifsShare: "TeslaCam/Model3",
    cifsUser: "archive-account-917",
    cifsPassword: "private archive password"
  },
  {
    ...baseValues,
    wifiCountry: "DE",
    archiveSystem: "nfs",
    nfsServer: "192.168.7.20",
    nfsShare: "/volume1/TeslaCam"
  },
  {
    ...baseValues,
    archiveSystem: "rsync",
    rsyncUser: "archive",
    rsyncServer: "backup.local",
    rsyncPath: "/srv/teslacam"
  },
  {
    ...baseValues,
    archiveSystem: "rclone",
    rcloneDrive: "encrypted-remote",
    rclonePath: "TeslaCam"
  },
  {
    ...baseValues,
    archiveSystem: "none",
    temperatureEnabled: false,
    sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3JyZk3lXv7jB5U9x1Qn4b1bMyC3whZQTn6fJZxqQ2f owner@example"
  }
];

const documents = profileInputs.map((profile) => wizard.buildDocument(profile));
for (const documentValue of documents) {
  assert.equal(documentValue.schema_version, 1);
  assert.equal(documentValue.variables.CAM_SIZE, "40G");
  assert.equal(documentValue.variables.ARCHIVE_RECENTCLIPS, false);
  assert.match(documentValue.variables.WIFI_COUNTRY, /^[A-Z]{2}$/);
  assert.equal(documentValue.variables.TIME_ZONE, "America/Chicago");
  assert.equal(documentValue.variables.WEB_USERNAME, "teslausb");
  for (const forbidden of [
    "DATA_DRIVE", "REPO", "BRANCH", "TESLAFI_API_TOKEN", "TESSIE_API_TOKEN",
    "TELEGRAM_BOT_TOKEN", "NTFY_TOKEN", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"
  ]) {
    assert.equal(Object.hasOwn(documentValue.variables, forbidden), false, `wizard emitted ${forbidden}`);
  }
}
assert.equal(documents[0].variables.ARCHIVE_SYSTEM, "none");
assert.equal(documents[0].variables.TEMPERATURE_CAUTION, 55000);
assert.equal(documents[0].variables.TEMPERATURE_WARNING, 68000);
assert.equal(documents[0].variables.TEMPERATURE_INTERVAL, 60);
assert.equal(documents[0].variables.TEMPERATURE_POSTARCHIVE, true);
assert.equal(documents.at(-1).variables.SSH_DISABLE_PASSWORD_AUTHENTICATION, true);
assert.equal(Object.hasOwn(documents.at(-1).variables, "TEMPERATURE_CAUTION"), false);

const redacted = wizard.serializeDocument(wizard.redactDocument(documents[1]));
for (const secret of [
  baseValues.ssid,
  baseValues.wifiPassword,
  baseValues.webPassword,
  profileInputs[1].cifsServer,
  profileInputs[1].cifsShare,
  profileInputs[1].cifsUser,
  profileInputs[1].cifsPassword
]) {
  assert.equal(redacted.includes(secret), false, "redacted preview exposed a sensitive value");
}
assert.match(redacted, /"WIFIPASS": "<redacted>"/);

for (const invalidCountry of ["USA", "UK", "ZZ"]) {
  assert.throws(
    () => wizard.buildDocument({...baseValues, wifiCountry: invalidCountry}),
    /valid ISO 3166-1 alpha-2/
  );
}
for (const validCountry of ["US", "DE"]) {
  assert.equal(
    wizard.buildDocument({...baseValues, wifiCountry: validCountry}).variables.WIFI_COUNTRY,
    validCountry
  );
}
assert.throws(() => wizard.buildDocument({...baseValues, timeZone: "auto"}), /named IANA/);
assert.throws(() => wizard.buildDocument({...baseValues, webPassword: "password"}), /12–72|default value/);
assert.throws(() => wizard.buildDocument({...baseValues, wifiPassword: "short"}), /8–63/);

function findPython() {
  const candidates = [process.env.TESLAUSB_TEST_PYTHON, "python3", "python"].filter(Boolean);
  for (const candidate of candidates) {
    const result = spawnSync(candidate, ["--version"], {encoding: "utf8"});
    if (!result.error && result.status === 0) return candidate;
  }
  throw new Error("Python 3 is required to validate wizard profiles");
}

const python = findPython();
const testDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "teslausb-config-wizard-test-"));
try {
  for (const [index, documentValue] of documents.entries()) {
    const configPath = path.join(testDirectory, `profile-${index}.json`);
    fs.writeFileSync(configPath, wizard.serializeDocument(documentValue), {encoding: "utf8", mode: 0o600});
    const validation = spawnSync(python, [validatorPath, "validate", configPath], {encoding: "utf8"});
    assert.equal(validation.status, 0, validation.stdout + validation.stderr);
    const combinedOutput = validation.stdout + validation.stderr;
    assert.equal(combinedOutput.includes(baseValues.wifiPassword), false);
    assert.equal(combinedOutput.includes(baseValues.webPassword), false);
  }
} finally {
  fs.rmSync(testDirectory, {recursive: true, force: true});
}

const stageScript = fs.readFileSync(stageScriptPath, "utf8");
assert.match(
  stageScript,
  /install -m 644 files\/teslausb_config_wizard\.html\s+"\$\{ROOTFS_DIR\}\/boot\/firmware\/teslausb_config_wizard\.html"/
);

console.log("config wizard tests passed");
