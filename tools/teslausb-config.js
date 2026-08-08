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
const path = require("node:path");

function loadIso3166CountryCodes() {
  const sourcePath = path.join(
    __dirname,
    "..",
    "pi-gen-sources",
    "00-teslausb-tweaks",
    "files",
    "iso3166-country-codes.json"
  );
  const documentValue = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
  const codes = documentValue.codes;
  if (documentValue.format !== 1 || documentValue.standard !== "ISO 3166-1 alpha-2" ||
      !Array.isArray(codes) || codes.length === 0 ||
      codes.some((code) => typeof code !== "string" || !/^[A-Z]{2}$/.test(code)) ||
      new Set(codes).size !== codes.length ||
      codes.some((code, index) => index > 0 && codes[index - 1] >= code)) {
    throw new Error("The canonical ISO 3166-1 alpha-2 country-code list is invalid");
  }
  return Object.freeze([...codes]);
}

const ISO3166_ALPHA2_CODES = loadIso3166CountryCodes();
const WIFI_COUNTRY_CODES = new Set(ISO3166_ALPHA2_CODES);

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
  "WEBUI_RELEASE", "WEBUI_SHA256", "WIFIPASS", "WIFI_COUNTRY"
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
  "SSID", "WIFIPASS", "WIFI_COUNTRY", "ARCHIVE_SYSTEM", "ARCHIVE_SERVER", "SHARE_NAME",
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
    /^(?:your(?:_|-)|put[_ -]|replace(?: