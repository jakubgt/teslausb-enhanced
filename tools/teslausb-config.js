#!/usr/bin/env node
"use strict";

/*
 * Local, dependency-free TeslaUSB configuration helper.
 *
 * This parser intentionally understands only literal `export NAME=value`
 * assignments. It never sources the configuration because that would execute
 * arbitrary shell code on the computer doing the preflight check.
 */

const fs = require("node:fs");
const net = require("node:net");

const VARIABLE_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const MAX_CONFIG_BYTES = 1024 * 1024;
const MAX_STRING_BYTES = 16 * 1024;
const MAX_ARRAY_ITEMS = 128;
const ARCHIVE_SYSTEMS = new Set(["cifs", "nfs", "rsync", "rclone", "none"]);
const DECLARATIVE_BOOLEAN_NAMES = new Set([
  "ARCHIVE_RECENTCLIPS", "ARCHIVE_SAVEDCLIPS", "ARCHIVE_SENTRYCLIPS", "ARCHIVE_TRACKMODECLIPS",
  "CONFIGURE_ARCHIVING", "DISCORD_ENABLED", "GOTIFY_ENABLED", "IFTTT_ENABLED", "MATRIX_ENABLED",
  "NOTIFICATION_COMMAND_ENABLED", "NTFY_ENABLED", "PUSHOVER_ENABLED", "SAMBA_ENABLED", "SAMBA_GUEST",
  "SIGNAL_ENABLED", "SKIP_READONLY", "SLACK_ENABLED", "SNAPSHOTS_ENABLED", "SNS_ENABLED",
  "SSH_ALLOW_DEFAULT_PASSWORD", "SSH_DISABLE_PASSWORD_AUTHENTICATION", "TELEGRAM_ENABLED",
  "TELEGRAM_SILENT_NOTIFY", "TEMPERATURE_POSTARCHIVE", "UPGRADE_PACKAGES", "USE_EXFAT",
  "WEBHOOK_ENABLED", "WEB_AUTH_DISABLED"
]);
const DECLARATIVE_INTEGER_RANGES = new Map([
  ["ARCHIVE_DELAY", [0, 86400]],
  ["ARCHIVE_RETRY_ATTEMPTS_PER_RUN", [1, 20]],
  ["ARCHIVE_RETRY_BASE_SECONDS", [1, 86400]],
  ["ARCHIVE_RETRY_MAX_SECONDS", [1, 604800]],
  ["ARCHIVE_RSYNC_TIMEOUT", [1, 86400]],
  ["AUTOFS_WAIT_SECONDS", [1, 600]],
  ["DIRTY_BACKGROUND_BYTES", [0, 2147483647]],
  ["DIRTY_RATIO", [0, 100]],
  ["FORCE_SYNC_TIMEOUT_SECONDS", [1, 86400]],
  ["GOTIFY_PRIORITY", [-2, 10]],
  ["MUSIC_RSYNC_TIMEOUT", [1, 86400]],
  ["NTFY_PRIORITY", [1, 5]],
  ["PIP_RETRIES", [0, 20]],
  ["PIP_TIMEOUT_SECONDS", [1, 600]],
  ["RCLONE_CONNECT_TIMEOUT", [1, 3600]],
  ["RCLONE_IO_TIMEOUT", [1, 86400]],
  ["RSYNC_SSH_CONNECT_TIMEOUT", [1, 3600]],
  ["SENTRY_CASE", [1, 3]],
  ["SNAPSHOT_INTERVAL", [60, 86400]],
  ["TEMPERATURE_CAUTION", [-100000, 200000]],
  ["TEMPERATURE_INTERVAL", [1, 86400]],
  ["TEMPERATURE_WARNING", [-100000, 200000]],
  ["TESLAUSB_CURL_CONNECT_TIMEOUT", [1, 3600]],
  ["TESLAUSB_CURL_MAX_TIME", [1, 86400]],
  ["TESLAUSB_NOTIFICATION_TIMEOUT_SECONDS", [1, 3600]],
  ["TESLA_BLE_ARTIFACT_MAX_BYTES", [1, 1073741824]],
  ["TESLA_BLE_COMMAND_TIMEOUT_SECONDS", [1, 3600]]
]);
const DECLARATIVE_INTEGER_NAMES = new Set(DECLARATIVE_INTEGER_RANGES.keys());
const DECLARATIVE_ARRAY_NAMES = new Set(["INSTALL_USER_REQUESTED_PACKAGES", "RCLONE_FLAGS"]);
const DECLARATIVE_STRING_NAMES = new Set([
  "AP_IP", "AP_PASS", "AP_SSID", "ARCHIVE_SERVER", "ARCHIVE_SYSTEM", "AWS_ACCESS_KEY_ID",
  "AWS_REGION", "AWS_SECRET_ACCESS_KEY", "AWS_SNS_TOPIC_ARN", "BOOMBOX_SIZE", "BRANCH",
  "CAM_SIZE", "CIFS_SEC", "CIFS_VERSION", "CPU_GOVERNOR", "DATA_DRIVE",
  "DISCORD_WEBHOOK_URL", "GOTIFY_APP_TOKEN", "GOTIFY_DOMAIN", "IFTTT_EVENT_NAME", "IFTTT_KEY",
  "INCREASE_ROOT_SIZE", "KEEP_AWAKE_WEBHOOK_URL", "LIGHTSHOW_SIZE", "MATRIX_PASSWORD",
  "MATRIX_ROOM", "MATRIX_SERVER_URL", "MATRIX_USERNAME", "MUSIC_SHARE_NAME", "MUSIC_SIZE",
  "NOTIFICATION_COMMAND_FINISH", "NOTIFICATION_COMMAND_START", "NOTIFICATION_TITLE", "NTFY_TOKEN",
  "NTFY_URL", "PUSHOVER_APP_KEY", "PUSHOVER_USER_KEY", "RCLONE_DRIVE", "RCLONE_PATH", "REPO",
  "RSYNC_PATH", "RSYNC_SERVER", "RSYNC_USER", "SAMBA_PASSWORD", "SAMBA_USER", "SHARE_DOMAIN",
  "SHARE_NAME", "SHARE_PASSWORD", "SHARE_USER", "SIGNAL_FROM_NUM", "SIGNAL_TO_NUM", "SIGNAL_URL",
  "SLACK_WEBHOOK_URL", "SSH_ROOT_PUBLIC_KEY", "SSH_USER_PASSWORD", "SSID", "TELEGRAM_BOT_TOKEN",
  "TELEGRAM_CHAT_ID", "TESLAFI_API_TOKEN", "TESLAUSB_HOSTNAME", "TESLA_BLE_ARTIFACT_FILE",
  "TESLA_BLE_ARTIFACT_SHA256", "TESLA_BLE_ARTIFACT_VERSION", "TESLA_BLE_VIN", "TESSIE_API_TOKEN",
  "TESSIE_VIN", "TIME_ZONE", "TRIGGER_FILE_ANY", "TRIGGER_FILE_RECENT", "TRIGGER_FILE_SAVED",
  "TRIGGER_FILE_SENTRY", "WEBHOOK_URL", "WEB_ALLOWED_HOSTS", "WEB_PASSWORD", "WEB_USERNAME",
  "WEBUI_RELEASE", "WEBUI_SHA256", "WIFIPASS"
]);
const DECLARATIVE_ALLOWED_NAMES = new Set([
  ...DECLARATIVE_BOOLEAN_NAMES,
  ...DECLARATIVE_INTEGER_NAMES,
  ...DECLARATIVE_ARRAY_NAMES,
  ...DECLARATIVE_STRING_NAMES
]);
const CIFS_VERSIONS = new Set(["default", "1.0", "2.0", "2.1", "3.0", "3.02", "3.1.1"]);
const CIFS_SECURITY_MODES = new Set([
  "none", "krb5", "krb5i", "ntlm", "ntlmi", "ntlmv2", "ntlmv2i", "ntlmssp", "ntlmsspi"
]);
const NOTIFICATION_REQUIREMENTS = new Map([
  ["SIGNAL_ENABLED", ["SIGNAL_URL", "SIGNAL_TO_NUM", "SIGNAL_FROM_NUM"]],
  ["PUSHOVER_ENABLED", ["PUSHOVER_USER_KEY", "PUSHOVER_APP_KEY"]],
  ["GOTIFY_ENABLED", ["GOTIFY_DOMAIN", "GOTIFY_APP_TOKEN", "GOTIFY_PRIORITY"]],
  ["DISCORD_ENABLED", ["DISCORD_WEBHOOK_URL"]],
  ["IFTTT_ENABLED", ["IFTTT_EVENT_NAME", "IFTTT_KEY"]],
  ["WEBHOOK_ENABLED", ["WEBHOOK_URL"]],
  ["SLACK_ENABLED", ["SLACK_WEBHOOK_URL"]],
  ["MATRIX_ENABLED", ["MATRIX_SERVER_URL", "MATRIX_USERNAME", "MATRIX_PASSWORD", "MATRIX_ROOM"]],
  ["SNS_ENABLED", ["AWS_REGION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SNS_TOPIC_ARN"]],
  ["TELEGRAM_ENABLED", ["TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID"]],
  ["NTFY_ENABLED", ["NTFY_URL"]]
]);
const KNOWN_PLACEHOLDER_VALUES = new Set([
  "password", "raspberry", "username", "hostname", "hostname_or_ip",
  "http://<url>:8080", "http://domain/path/", "https://gotify.domain.com",
  "country_code_and_number_configured_with_signal", "123456789",
  "bot123456789:abcdefghijklmnopqrstuvqxyz987654321"
]);
const CANONICAL_ORDER = [
  "SSID", "WIFIPASS", "ARCHIVE_SYSTEM", "ARCHIVE_SERVER", "SHARE_NAME",
  "SHARE_USER", "SHARE_PASSWORD", "RSYNC_USER", "RSYNC_SERVER", "RSYNC_PATH",
  "RCLONE_DRIVE", "RCLONE_PATH", "CAM_SIZE", "MUSIC_SIZE", "LIGHTSHOW_SIZE",
  "BOOMBOX_SIZE", "WEB_USERNAME", "WEB_PASSWORD", "WEB_ALLOWED_HOSTS",
  "WEBUI_RELEASE", "WEBUI_SHA256",
  "SAMBA_ENABLED", "SAMBA_GUEST", "SAMBA_USER", "SAMBA_PASSWORD",
  "AP_SSID", "AP_PASS", "AP_IP", "TESLAUSB_HOSTNAME",
  "SSH_ROOT_PUBLIC_KEY", "SSH_USER_PASSWORD", "SSH_ALLOW_DEFAULT_PASSWORD",
  "SSH_DISABLE_PASSWORD_AUTHENTICATION", "TIME_ZONE"
];

const SENSITIVE_NAME = /(?:(?:^|_)SSID$|WIFIPASS|PASS(?:WORD)?|TOKEN|SECRET|(?:^|_)KEY(?:_|$)|WEBHOOK_URL|SIGNAL_URL|NTFY_URL|SSH_ROOT_PUBLIC_KEY|(?:^|_)VIN$|ARCHIVE_SERVER|RSYNC_SERVER|SHARE_NAME|SHARE_USER|RSYNC_USER|MATRIX_(?:USERNAME|ROOM)|TELEGRAM_CHAT_ID|TESLAUSB_HOSTNAME|WEB_ALLOWED_HOSTS|NOTIFICATION_COMMAND)/;

function bashQuote(value) {
  const input = String(value);
  if (input.includes("\0")) {
    throw new Error("Configuration values cannot contain NUL characters");
  }
  let escaped = "";
  for (const char of input) {
    const code = char.codePointAt(0);
    if (char === "\\") escaped += "\\\\";
    else if (char === "'") escaped += "\\'";
    else if (char === "\n") escaped += "\\n";
    else if (char === "\r") escaped += "\\r";
    else if (char === "\t") escaped += "\\t";
    else if (code < 0x20 || code === 0x7f) escaped += `\\x${code.toString(16).padStart(2, "0")}`;
    else escaped += char;
  }
  return `$'${escaped}'`;
}

function decodeAnsiCString(body) {
  let output = "";
  for (let index = 0; index < body.length; index += 1) {
    const char = body[index];
    if (char !== "\\") {
      output += char;
      continue;
    }
    index += 1;
    if (index >= body.length) throw new Error("trailing backslash");
    const escaped = body[index];
    if (escaped === "n") output += "\n";
    else if (escaped === "r") output += "\r";
    else if (escaped === "t") output += "\t";
    else if (escaped === "\\" || escaped === "'") output += escaped;
    else if (escaped === "x") {
      const digits = body.slice(index + 1, index + 3);
      if (!/^[0-9a-fA-F]{2}$/.test(digits)) throw new Error("invalid hexadecimal escape");
      output += String.fromCodePoint(Number.parseInt(digits, 16));
      index += 2;
    } else {
      throw new Error(`unsupported escape \\${escaped}`);
    }
  }
  return output;
}

function stripInlineComment(raw) {
  let quote = null;
  let escaped = false;
  for (let index = 0; index < raw.length; index += 1) {
    const char = raw[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote === "single") {
      if (char === "'") quote = null;
      continue;
    }
    if (quote === "double" || quote === "ansi") {
      if (char === "\\") escaped = true;
      else if ((quote === "double" && char === '"') || (quote === "ansi" && char === "'")) quote = null;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === "$" && raw[index + 1] === "'") {
      quote = "ansi";
      index += 1;
      continue;
    }
    if (char === "'") {
      quote = "single";
      continue;
    }
    if (char === '"') {
      quote = "double";
      continue;
    }
    if (char === "#" && (index === 0 || /\s/.test(raw[index - 1]))) {
      return raw.slice(0, index).trimEnd();
    }
  }
  return raw.trimEnd();
}

function closingQuoteIndex(raw, start, quote, backslashEscapes) {
  for (let index = start; index < raw.length; index += 1) {
    if (raw[index] === "\\" && backslashEscapes) {
      index += 1;
      continue;
    }
    if (raw[index] === quote) return index;
  }
  return -1;
}

function decodeLiteral(rawValue) {
  const raw = stripInlineComment(rawValue).trim();
  if (raw === "") return "";
  if (raw.startsWith("$'")) {
    const closing = closingQuoteIndex(raw, 2, "'", true);
    if (closing === -1) throw new Error("unterminated ANSI-C quoted value");
    if (closing !== raw.length - 1) throw new Error("ANSI-C quoted value must be one literal token");
    return decodeAnsiCString(raw.slice(2, closing));
  }
  if (raw.startsWith("'")) {
    const closing = closingQuoteIndex(raw, 1, "'", false);
    if (closing === -1) throw new Error("unterminated single-quoted value");
    if (closing !== raw.length - 1) throw new Error("single-quoted value must be one literal token");
    return raw.slice(1, closing);
  }
  if (raw.startsWith('"')) {
    const closing = closingQuoteIndex(raw, 1, '"', true);
    if (closing === -1) throw new Error("unterminated double-quoted value");
    if (closing !== raw.length - 1) throw new Error("double-quoted value must be one literal token");
    const body = raw.slice(1, closing);
    if (/[$`]/.test(body)) throw new Error("variable and command expansion are not accepted");
    return body.replace(/\\([\\"])/g, "$1");
  }
  if (raw.startsWith("(") && raw.endsWith(")")) {
    validateLiteralArray(raw.slice(1, -1));
    return raw;
  }
  if (/[;&|<>(){}$`]/.test(raw)) throw new Error("shell expressions are not accepted");
  if (/['"]/.test(raw)) throw new Error("mixed quoted and unquoted values are not accepted");

  let output = "";
  for (let index = 0; index < raw.length; index += 1) {
    if (raw[index] === "\\") {
      index += 1;
      if (index >= raw.length) throw new Error("trailing backslash");
      output += raw[index];
    } else {
      if (/\s/.test(raw[index])) throw new Error("unquoted whitespace");
      output += raw[index];
    }
  }
  return output;
}

function validateLiteralArray(body) {
  const tokens = [];
  let token = "";
  let quote = null;
  let escaped = false;

  const finishToken = () => {
    if (token !== "") {
      tokens.push(token);
      token = "";
    }
  };

  for (let index = 0; index < body.length; index += 1) {
    const char = body[index];
    if (escaped) {
      token += char;
      escaped = false;
      continue;
    }
    if (quote === "single") {
      token += char;
      if (char === "'") quote = null;
      continue;
    }
    if (quote === "double" || quote === "ansi") {
      token += char;
      if (char === "\\") {
        escaped = true;
      } else if ((quote === "double" && char === '"') || (quote === "ansi" && char === "'")) {
        quote = null;
      }
      continue;
    }
    if (/\s/.test(char)) {
      finishToken();
      continue;
    }
    if (char === "\\") {
      token += char;
      escaped = true;
      continue;
    }
    if (char === "$" && body[index + 1] === "'") {
      if (token !== "") {
        throw new Error("mixed quoted array tokens are not accepted");
      }
      token = "$'";
      quote = "ansi";
      index += 1;
      continue;
    }
    if (char === "'" || char === '"') {
      if (token !== "") throw new Error("mixed quoted array tokens are not accepted");
      token += char;
      quote = char === "'" ? "single" : "double";
      continue;
    }
    if (/[;&|<>(){}$`]/.test(char)) {
      throw new Error("array contains a shell expression");
    }
    token += char;
  }
  if (escaped || quote) throw new Error("unterminated array token");
  finishToken();
  return tokens.map((item) => decodeLiteral(item));
}

function parseConfig(text) {
  const assignments = new Map();
  const issues = [];
  const lines = String(text).replace(/^\uFEFF/, "").split(/\r?\n/);

  lines.forEach((line, offset) => {
    const lineNumber = offset + 1;
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) return;
    const match = line.match(/^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)\s*=([\s\S]*)$/);
    if (!match) {
      issues.push({level: "error", line: lineNumber, message: "expected a literal export NAME=value assignment"});
      return;
    }
    const [, name, raw] = match;
    try {
      const value = decodeLiteral(raw);
      if (assignments.has(name)) {
        issues.push({level: "warning", line: lineNumber, message: `${name} is assigned more than once; the last value wins`});
      }
      assignments.set(name, {name, value, raw, line: lineNumber});
    } catch (error) {
      issues.push({level: "error", line: lineNumber, message: `${name}: ${error.message}`});
    }
  });

  return {assignments, issues};
}

function looksLikePlaceholder(value) {
  const candidate = String(value).trim().toLowerCase();
  return KNOWN_PLACEHOLDER_VALUES.has(candidate) ||
    /^(?:your(?:_|-)|put[_ -]|replace(?:_|-)|choose-a-unique-|your_archive)/.test(candidate) ||
    /<[^>]+>/.test(candidate) || /(?:_|-)goes(?:_|-)here$/.test(candidate);
}

function isSafeDnsHostname(value) {
  const text = String(value);
  if (text.length < 1 || text.length > 253) return false;
  return text.split(".").every((label) =>
    /^(?=.{1,63}$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(label));
}

function isAllowedWebHost(value) {
  const text = String(value);
  const candidate = text.startsWith("[") && text.endsWith("]")
    ? text.slice(1, -1)
    : text;
  return net.isIP(candidate) !== 0 || isSafeDnsHostname(candidate);
}

function hasControlCharacter(value) {
  return /[\x00-\x1f\x7f]/.test(String(value));
}

function isSafeTimeZone(value) {
  const candidate = String(value);
  if (candidate === "auto") return true;
  if (!candidate || Buffer.byteLength(candidate, "utf8") > 255 || candidate.startsWith("/") || candidate.startsWith("\\")) {
    return false;
  }
  return candidate.split("/").every((part) =>
    part !== "." && part !== ".." && /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(part));
}

function isSafeTriggerName(value) {
  const candidate = String(value);
  return candidate !== "" && candidate !== "." && candidate !== ".." &&
    !candidate.includes("/") && !candidate.includes("\\") &&
    Buffer.byteLength(candidate, "utf8") <= 255 && !hasControlCharacter(candidate);
}

function isSafeDevicePath(value) {
  const candidate = String(value);
  if (!candidate.startsWith("/dev/")) return false;
  return candidate.slice("/dev/".length).split("/").every((part) =>
    part !== "" && part !== "." && part !== ".." &&
    /^[A-Za-z0-9][A-Za-z0-9._+:-]*$/.test(part));
}

function isSafeGitRef(value) {
  const candidate = String(value);
  if (!candidate || candidate.length > 255 || !/^[A-Za-z0-9._/-]+$/.test(candidate) ||
      candidate.startsWith("/") || candidate.endsWith("/") || candidate.includes("..") ||
      candidate.includes("//") || candidate.includes("@{")) {
    return false;
  }
  return candidate.split("/").every((part) =>
    part && !part.startsWith(".") && !part.endsWith(".") && !part.endsWith(".lock"));
}

function declarativeSchema() {
  return {
    booleanNames: [...DECLARATIVE_BOOLEAN_NAMES].sort(),
    integerRanges: Object.fromEntries([...DECLARATIVE_INTEGER_RANGES].sort(([left], [right]) => left.localeCompare(right))),
    arrayNames: [...DECLARATIVE_ARRAY_NAMES].sort(),
    stringNames: [...DECLARATIVE_STRING_NAMES].sort()
  };
}

function preflightConfig(text) {
  const parsed = parseConfig(text);
  const issues = [...parsed.issues];
  const value = (name) => parsed.assignments.get(name)?.value;
  const present = (name) => value(name) !== undefined && value(name) !== "";
  const add = (level, message, name) => issues.push({
    level,
    line: name && parsed.assignments.get(name) ? parsed.assignments.get(name).line : undefined,
    message
  });
  const requireValue = (name, reason) => {
    if (!present(name)) add("error", `${name} is required ${reason || ""}`.trim(), name);
    else if (looksLikePlaceholder(value(name))) add("error", `${name} still contains a sample placeholder`, name);
  };
  const requirePair = (left, right) => {
    if (present(left) !== present(right)) add("error", `${left} and ${right} must either both be set or both be omitted`, present(left) ? left : right);
  };

  for (const [name, assignment] of parsed.assignments) {
    if (hasControlCharacter(assignment.value)) {
      add("error", `${name} must not contain control characters`, name);
    }
    if (!DECLARATIVE_ARRAY_NAMES.has(name) &&
        Buffer.byteLength(String(assignment.value), "utf8") > MAX_STRING_BYTES) {
      add("error", `${name} exceeds ${MAX_STRING_BYTES} UTF-8 bytes`, name);
    }
  }

  for (const [name, [minimum, maximum]] of DECLARATIVE_INTEGER_RANGES) {
    if (!present(name)) continue;
    if (!/^-?[0-9]+$/.test(value(name))) {
      add("error", `${name} must be a decimal integer`, name);
      continue;
    }
    const integer = Number(value(name));
    if (!Number.isSafeInteger(integer) || integer < minimum || integer > maximum) {
      add("error", `${name} must be between ${minimum} and ${maximum}`, name);
    }
  }

  requirePair("SSID", "WIFIPASS");
  if (!present("SSID") && !present("WIFIPASS")) {
    add("warning", "SSID and WIFIPASS are absent; this is valid only when networking is already configured");
  } else {
    requireValue("SSID");
    requireValue("WIFIPASS");
  }

  requireValue("ARCHIVE_SYSTEM");
  const archiveSystem = value("ARCHIVE_SYSTEM");
  if (archiveSystem && !ARCHIVE_SYSTEMS.has(archiveSystem)) {
    add("error", `ARCHIVE_SYSTEM must be one of: ${[...ARCHIVE_SYSTEMS].join(", ")}`, "ARCHIVE_SYSTEM");
  } else if (archiveSystem === "cifs") {
    for (const name of ["ARCHIVE_SERVER", "SHARE_NAME", "SHARE_USER", "SHARE_PASSWORD"]) requireValue(name, "for CIFS archiving");
  } else if (archiveSystem === "nfs") {
    for (const name of ["ARCHIVE_SERVER", "SHARE_NAME"]) requireValue(name, "for NFS archiving");
  } else if (archiveSystem === "rsync") {
    for (const name of ["RSYNC_USER", "RSYNC_SERVER", "RSYNC_PATH"]) requireValue(name, "for rsync archiving");
  } else if (archiveSystem === "rclone") {
    for (const name of ["RCLONE_DRIVE", "RCLONE_PATH"]) requireValue(name, "for rclone archiving");
  }

  requireValue("CAM_SIZE");
  for (const name of ["CAM_SIZE", "MUSIC_SIZE", "LIGHTSHOW_SIZE", "BOOMBOX_SIZE", "INCREASE_ROOT_SIZE"]) {
    if (present(name) && !/^[1-9][0-9]*(?:[KMGTP])?$/i.test(value(name))) {
      add("error", `${name} must be a positive size such as 40G or 512M`, name);
    }
  }

  requirePair("WEB_USERNAME", "WEB_PASSWORD");
  if (!present("WEB_USERNAME") && !present("WEB_PASSWORD")) {
    add("warning", "WEB_USERNAME and WEB_PASSWORD are absent; setup will generate root-only web credentials, so configure console or SSH access to retrieve them");
  } else if (present("WEB_USERNAME") && present("WEB_PASSWORD")) {
    if (!/^[A-Za-z0-9_.@-]{1,64}$/.test(value("WEB_USERNAME"))) {
      add("error", "WEB_USERNAME must be 1-64 letters, numbers, dots, underscores, at signs, or dashes", "WEB_USERNAME");
    }
    const webPasswordBytes = Buffer.byteLength(value("WEB_PASSWORD"), "utf8");
    if (/[\r\n]/.test(value("WEB_PASSWORD"))) {
      add("error", "WEB_PASSWORD must not contain a newline", "WEB_PASSWORD");
    } else if (/^(?:raspberry|password|teslausb)$/i.test(value("WEB_PASSWORD")) ||
               value("WEB_PASSWORD").toLowerCase() === value("WEB_USERNAME").toLowerCase()) {
      add("error", "WEB_PASSWORD uses an unsafe default or matches WEB_USERNAME", "WEB_PASSWORD");
    } else if (webPasswordBytes < 12 || webPasswordBytes > 72) {
      add("error", "WEB_PASSWORD must be between 12 and 72 UTF-8 bytes for bcrypt", "WEB_PASSWORD");
    }
  }
  requirePair("AP_SSID", "AP_PASS");
  if (value("AP_SSID") !== undefined) {
    const ssidBytes = Buffer.byteLength(value("AP_SSID"), "utf8");
    if (ssidBytes < 1 || ssidBytes > 32) {
      add("error", "AP_SSID must be 1-32 UTF-8 bytes", "AP_SSID");
    }
  }
  if (value("AP_PASS") !== undefined) {
    const passphraseBytes = Buffer.byteLength(value("AP_PASS"), "utf8");
    if (passphraseBytes < 8 || passphraseBytes > 63 || value("AP_PASS").toLowerCase() === "password") {
      add("error", "AP_PASS must be 8-63 UTF-8 bytes and must not use the sample password", "AP_PASS");
    }
  }
  if (present("AP_IP")) {
    const octets = value("AP_IP").split(".");
    const finalOctet = octets.length === 4 ? Number(octets[3]) : Number.NaN;
    if (net.isIP(value("AP_IP")) !== 4) {
      add("error", "AP_IP must be an IPv4 address", "AP_IP");
    } else if (!Number.isInteger(finalOctet) || finalOctet < 1 || finalOctet > 9) {
      add("error", "AP_IP must end in .1 through .9, outside the .10-.254 DHCP pool", "AP_IP");
    }
  }
  if (present("ARCHIVE_SERVER") && !isAllowedWebHost(value("ARCHIVE_SERVER"))) {
    add("error", "ARCHIVE_SERVER must be an exact DNS name or IP address without a port", "ARCHIVE_SERVER");
  }
  if (archiveSystem === "nfs" && present("SHARE_NAME") && !value("SHARE_NAME").startsWith("/")) {
    add("error", "SHARE_NAME must be an absolute exported path for NFS archiving", "SHARE_NAME");
  }
  if (present("CIFS_VERSION") && !CIFS_VERSIONS.has(value("CIFS_VERSION"))) {
    add("error", `CIFS_VERSION must be one of: ${[...CIFS_VERSIONS].sort().join(", ")}`, "CIFS_VERSION");
  }
  if (present("CIFS_SEC") && !CIFS_SECURITY_MODES.has(value("CIFS_SEC"))) {
    add("error", `CIFS_SEC must be one of: ${[...CIFS_SECURITY_MODES].sort().join(", ")}`, "CIFS_SEC");
  }
  if (present("REPO") && !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/.test(value("REPO"))) {
    add("error", "REPO is not a valid GitHub owner name", "REPO");
  }
  if (present("BRANCH") && !isSafeGitRef(value("BRANCH"))) {
    add("error", "BRANCH is not a safe Git reference", "BRANCH");
  }
  if (present("TIME_ZONE") && !isSafeTimeZone(value("TIME_ZONE"))) {
    add("error", "TIME_ZONE must be auto or a relative zoneinfo name without traversal", "TIME_ZONE");
  }
  for (const name of ["TRIGGER_FILE_ANY", "TRIGGER_FILE_RECENT", "TRIGGER_FILE_SAVED", "TRIGGER_FILE_SENTRY"]) {
    if (value(name) !== undefined && !isSafeTriggerName(value(name))) {
      add("error", `${name} must be one filename, not a path`, name);
    }
  }
  if (present("WEB_ALLOWED_HOSTS")) {
    const allowedHosts = String(value("WEB_ALLOWED_HOSTS")).split(/[\s,]+/).filter(Boolean);
    if (allowedHosts.length === 0 || allowedHosts.some((host) => !isAllowedWebHost(host))) {
      add("error", "WEB_ALLOWED_HOSTS must contain comma/space-separated exact DNS names or IP addresses without ports", "WEB_ALLOWED_HOSTS");
    }
  }
  requirePair("WEBUI_RELEASE", "WEBUI_SHA256");
  if (present("WEBUI_RELEASE") &&
      (!/^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/.test(value("WEBUI_RELEASE")) ||
       value("WEBUI_RELEASE").includes(".."))) {
    add("error", "WEBUI_RELEASE must start/end with a letter or number, contain only tag-safe characters, and contain no dot-dot sequence", "WEBUI_RELEASE");
  } else if (present("WEBUI_RELEASE") && value("WEBUI_RELEASE").toLowerCase() === "latest") {
    add("error", "WEBUI_RELEASE must name an immutable release and must not be latest", "WEBUI_RELEASE");
  }
  if (present("WEBUI_SHA256") && !/^[0-9a-f]{64}$/i.test(value("WEBUI_SHA256"))) {
    add("error", "WEBUI_SHA256 must be exactly 64 hexadecimal characters", "WEBUI_SHA256");
  }
  if (present("DATA_DRIVE")) {
    if (!isSafeDevicePath(value("DATA_DRIVE"))) {
      add("error", "DATA_DRIVE must be an absolute whole-disk path under /dev without traversal", "DATA_DRIVE");
    }
    add("warning", `DATA_DRIVE=${value("DATA_DRIVE")} will be wiped and repartitioned during setup`, "DATA_DRIVE");
  }
  if (present("TESLAUSB_HOSTNAME") &&
      !/^(?=.{1,63}$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(value("TESLAUSB_HOSTNAME"))) {
    add("error", "TESLAUSB_HOSTNAME must be one DNS label (1-63 characters, letters/numbers at both edges, with optional internal hyphens)", "TESLAUSB_HOSTNAME");
  }
  if (value("SAMBA_ENABLED") === "true" && value("SAMBA_GUEST") !== "true") {
    requireValue("SAMBA_PASSWORD", "when authenticated Samba sharing is enabled");
    if (present("SAMBA_PASSWORD")) {
      const sambaPasswordBytes = Buffer.byteLength(value("SAMBA_PASSWORD"), "utf8");
      if (sambaPasswordBytes < 12 || /^(?:raspberry|password)$/i.test(value("SAMBA_PASSWORD"))) {
        add("error", "SAMBA_PASSWORD must be a non-default password of at least 12 UTF-8 bytes", "SAMBA_PASSWORD");
      }
    }
  }
  if (value("WEB_AUTH_DISABLED") === "true" && (present("WEB_USERNAME") || present("WEB_PASSWORD"))) {
    add("error", "WEB_AUTH_DISABLED cannot be combined with WEB_USERNAME or WEB_PASSWORD", "WEB_AUTH_DISABLED");
  }
  if (value("SSH_ALLOW_DEFAULT_PASSWORD") === "true") {
    add("warning", "SSH_ALLOW_DEFAULT_PASSWORD=true explicitly retains the image's default SSH password", "SSH_ALLOW_DEFAULT_PASSWORD");
  }
  if (present("SSH_USER_PASSWORD") && Buffer.byteLength(value("SSH_USER_PASSWORD"), "utf8") < 12) {
    add("error", "SSH_USER_PASSWORD must be at least 12 UTF-8 bytes with no newline", "SSH_USER_PASSWORD");
  }
  if (present("TESLA_BLE_ARTIFACT_SHA256") && !/^[0-9a-f]{64}$/i.test(value("TESLA_BLE_ARTIFACT_SHA256"))) {
    add("error", "TESLA_BLE_ARTIFACT_SHA256 must be exactly 64 hexadecimal characters", "TESLA_BLE_ARTIFACT_SHA256");
  }
  for (const name of ["TESLA_BLE_VIN", "TESSIE_VIN"]) {
    if (present(name) && !/^[A-HJ-NPR-Za-hj-npr-z0-9]{17}$/.test(value(name))) {
      add("error", `${name} must be a 17-character VIN`, name);
    }
  }
  const keepAwakeNames = ["TESLAFI_API_TOKEN", "TESSIE_API_TOKEN", "TESLA_BLE_VIN", "KEEP_AWAKE_WEBHOOK_URL"];
  const keepAwakeConfigured = keepAwakeNames.filter((name) => present(name));
  if (keepAwakeConfigured.length > 1) {
    add("error", `Only one keep-awake method may be configured: ${keepAwakeConfigured.join(", ")}`);
  }
  if (keepAwakeConfigured.length > 0) {
    requireValue("SENTRY_CASE", "when a keep-awake method is configured");
  }
  if (present("TESLAFI_API_TOKEN") && !/^[12]$/.test(value("SENTRY_CASE") || "")) {
    add("error", "SENTRY_CASE must be 1 or 2 for TeslaFi", "SENTRY_CASE");
  }
  if (present("TESSIE_API_TOKEN")) {
    requireValue("TESSIE_VIN", "when Tessie is configured");
  }
  if (present("ARCHIVE_RETRY_BASE_SECONDS") && present("ARCHIVE_RETRY_MAX_SECONDS") &&
      Number(value("ARCHIVE_RETRY_BASE_SECONDS")) > Number(value("ARCHIVE_RETRY_MAX_SECONDS"))) {
    add("error", "ARCHIVE_RETRY_BASE_SECONDS must not exceed ARCHIVE_RETRY_MAX_SECONDS", "ARCHIVE_RETRY_BASE_SECONDS");
  }

  for (const [enabledName, requiredNames] of NOTIFICATION_REQUIREMENTS) {
    if (value(enabledName) === "true") {
      for (const requiredName of requiredNames) requireValue(requiredName, `when ${enabledName}=true`);
    }
  }
  if (value("NOTIFICATION_COMMAND_ENABLED") === "true" &&
      !present("NOTIFICATION_COMMAND_START") && !present("NOTIFICATION_COMMAND_FINISH")) {
    add("error", "NOTIFICATION_COMMAND_START or NOTIFICATION_COMMAND_FINISH is required when NOTIFICATION_COMMAND_ENABLED=true", "NOTIFICATION_COMMAND_ENABLED");
  }

  for (const [name, assignment] of parsed.assignments) {
    if (looksLikePlaceholder(assignment.value)) {
      add("error", `${name} still contains a sample placeholder`, name);
    }
    if (String(assignment.value).includes("<redacted>")) {
      add("error", `${name} is redacted; use the original configuration for installation`, name);
    }
  }

  return {assignments: parsed.assignments, issues};
}

function generateConfig(input) {
  const variables = input && input.variables ? input.variables : input;
  if (!variables || Array.isArray(variables) || typeof variables !== "object") {
    throw new Error("Generator input must be a JSON object or an object with a variables property");
  }
  const names = Object.keys(variables).filter((name) => variables[name] !== null && variables[name] !== undefined);
  for (const name of names) {
    if (!VARIABLE_NAME.test(name)) throw new Error(`Invalid variable name: ${name}`);
    const candidate = variables[name];
    if (typeof candidate === "object" && !Array.isArray(candidate)) {
      throw new Error(`${name} must be a string, number, boolean, or array`);
    }
    if (Array.isArray(candidate) && candidate.some((item) =>
      item === null || item === undefined || !["string", "number", "boolean"].includes(typeof item))) {
      throw new Error(`${name} array values must be strings, numbers, or booleans`);
    }
  }
  names.sort((left, right) => {
    const leftIndex = CANONICAL_ORDER.indexOf(left);
    const rightIndex = CANONICAL_ORDER.indexOf(right);
    if (leftIndex !== -1 || rightIndex !== -1) {
      if (leftIndex === -1) return 1;
      if (rightIndex === -1) return -1;
      return leftIndex - rightIndex;
    }
    return left.localeCompare(right);
  });
  const output = [
    "# Generated locally by tools/teslausb-config.js.",
    "# This file contains secrets. Keep it private and do not commit it.",
    ""
  ];
  for (const name of names) {
    const candidate = variables[name];
    if (Array.isArray(candidate)) {
      output.push(`export ${name}=(${candidate.map(bashQuote).join(" ")})`);
    } else {
      output.push(`export ${name}=${bashQuote(candidate)}`);
    }
  }
  return `${output.join("\n")}\n`;
}

function migrateConfig(text) {
  const result = preflightConfig(text);
  const errors = result.issues.filter((issue) => issue.level === "error");
  if (errors.length > 0) {
    throw new Error(`Legacy configuration failed preflight: ${errors.map((issue) => issue.message).join("; ")}`);
  }

  const unsupported = [...result.assignments.keys()]
    .filter((name) => !DECLARATIVE_ALLOWED_NAMES.has(name))
    .sort();
  if (unsupported.length > 0) {
    throw new Error(`Unsupported variable(s) cannot be migrated: ${unsupported.join(", ")}`);
  }

  const variables = {};
  for (const [name, assignment] of result.assignments) {
    if (DECLARATIVE_BOOLEAN_NAMES.has(name)) {
      if (assignment.value !== "true" && assignment.value !== "false") {
        throw new Error(`${name} must be exactly true or false before migration`);
      }
      variables[name] = assignment.value === "true";
    } else if (DECLARATIVE_INTEGER_NAMES.has(name)) {
      if (!/^-?[0-9]+$/.test(assignment.value)) {
        throw new Error(`${name} must be a decimal integer before migration`);
      }
      const integer = Number(assignment.value);
      if (!Number.isSafeInteger(integer)) {
        throw new Error(`${name} is outside JavaScript's safe integer range`);
      }
      const [minimum, maximum] = DECLARATIVE_INTEGER_RANGES.get(name);
      if (integer < minimum || integer > maximum) {
        throw new Error(`${name} must be between ${minimum} and ${maximum} before migration`);
      }
      variables[name] = integer;
    } else if (DECLARATIVE_ARRAY_NAMES.has(name)) {
      const raw = stripInlineComment(assignment.raw).trim();
      if (raw.startsWith("(") && raw.endsWith(")")) {
        variables[name] = validateLiteralArray(raw.slice(1, -1));
      } else if (name === "INSTALL_USER_REQUESTED_PACKAGES") {
        variables[name] = String(assignment.value).trim().split(/\s+/).filter(Boolean);
      } else {
        throw new Error(`${name} must use a literal shell array before migration`);
      }
      if (variables[name].length > MAX_ARRAY_ITEMS) {
        throw new Error(`${name} contains more than ${MAX_ARRAY_ITEMS} items`);
      }
      for (const [index, item] of variables[name].entries()) {
        if (hasControlCharacter(item) || Buffer.byteLength(item, "utf8") > MAX_STRING_BYTES) {
          throw new Error(`${name}[${index}] is too large or contains a control character`);
        }
        if (name === "INSTALL_USER_REQUESTED_PACKAGES" &&
            !/^[A-Za-z0-9][A-Za-z0-9+.-]*$/.test(item)) {
          throw new Error(`unsupported package name: ${item}`);
        }
      }
    } else {
      variables[name] = String(assignment.value);
    }
  }

  const output = `${JSON.stringify({schema_version: 1, variables}, null, 2)}\n`;
  if (Buffer.byteLength(output, "utf8") > MAX_CONFIG_BYTES) {
    throw new Error(`migrated JSON exceeds ${MAX_CONFIG_BYTES} bytes`);
  }
  return output;
}

function sanitizeConfig(text) {
  const output = [
    "# SANITIZED TESLAUSB CONFIGURATION COPY",
    "# Redacted assignments are commented out. This file is for support/review, not installation."
  ];
  for (const line of String(text).replace(/^\uFEFF/, "").split(/\r?\n/)) {
    const match = line.match(/^(\s*)(#\s*)?export\s+([A-Za-z_][A-Za-z0-9_]*)\s*=([\s\S]*)$/);
    if (!match || !SENSITIVE_NAME.test(match[3])) {
      output.push(line);
      continue;
    }
    const [, indent, comment, name] = match;
    if (comment) output.push(`${indent}# export ${name}=${bashQuote("<redacted>")}`);
    else output.push(`${indent}# SANITIZED: export ${name}=${bashQuote("<redacted>")}`);
  }
  return output.join("\n");
}

function printIssues(result, stream = process.stdout) {
  if (result.issues.length === 0) {
    stream.write("Preflight passed with no findings.\n");
    return;
  }
  for (const issue of result.issues) {
    const where = issue.line ? `line ${issue.line}: ` : "";
    stream.write(`${issue.level.toUpperCase()}: ${where}${issue.message}\n`);
  }
}

function readText(path) {
  return fs.readFileSync(path === "-" ? 0 : path, "utf8");
}

function writeNewFile(path, contents) {
  if (!path || path === "-") {
    process.stdout.write(contents);
    return;
  }
  fs.writeFileSync(path, contents, {encoding: "utf8", flag: "wx", mode: 0o600});
}

function usage() {
  return [
    "Usage:",
    "  node tools/teslausb-config.js generate VALUES.json [OUTPUT.conf]",
    "  node tools/teslausb-config.js migrate CONFIG.conf [OUTPUT.json]",
    "  node tools/teslausb-config.js preflight CONFIG.conf",
    "  node tools/teslausb-config.js sanitize CONFIG.conf [SANITIZED.conf]",
    "",
    "Use '-' as an input or output path for stdin/stdout. Existing output files are never overwritten."
  ].join("\n");
}

function main(argv) {
  const [command, inputPath, outputPath] = argv;
  if (!command || !inputPath || !["generate", "migrate", "preflight", "sanitize"].includes(command)) {
    process.stderr.write(`${usage()}\n`);
    return 2;
  }
  if (command === "generate") {
    const generated = generateConfig(JSON.parse(readText(inputPath)));
    const result = preflightConfig(generated);
    printIssues(result, process.stderr);
    if (result.issues.some((issue) => issue.level === "error")) return 1;
    writeNewFile(outputPath || "-", generated);
    return 0;
  }
  if (command === "sanitize") {
    writeNewFile(outputPath || "-", sanitizeConfig(readText(inputPath)));
    return 0;
  }
  if (command === "migrate") {
    writeNewFile(outputPath || "-", migrateConfig(readText(inputPath)));
    return 0;
  }
  const result = preflightConfig(readText(inputPath));
  printIssues(result);
  return result.issues.some((issue) => issue.level === "error") ? 1 : 0;
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  bashQuote,
  declarativeSchema,
  decodeLiteral,
  generateConfig,
  migrateConfig,
  parseConfig,
  preflightConfig,
  sanitizeConfig
};
