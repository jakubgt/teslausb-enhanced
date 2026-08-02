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
const ARCHIVE_SYSTEMS = new Set(["cifs", "nfs", "rsync", "rclone", "none"]);
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
  for (const item of tokens) decodeLiteral(item);
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
  return /^(?:your(?:_|-)|put[_ -]|password$|username$|hostname(?:_or_ip)?$|your_archive|<.+>|.*GOES_HERE)$/i.test(String(value).trim());
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
  for (const name of ["CAM_SIZE", "MUSIC_SIZE", "LIGHTSHOW_SIZE", "BOOMBOX_SIZE"]) {
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
  if (present("AP_PASS") && (value("AP_PASS").length < 8 || value("AP_PASS") === "password")) {
    add("error", "AP_PASS must be at least 8 characters and must not use the sample password", "AP_PASS");
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
  if (value("SSH_ALLOW_DEFAULT_PASSWORD") === "true") {
    add("warning", "SSH_ALLOW_DEFAULT_PASSWORD=true explicitly retains the image's default SSH password", "SSH_ALLOW_DEFAULT_PASSWORD");
  }
  if (present("SSH_USER_PASSWORD") && /[\r\n]/.test(value("SSH_USER_PASSWORD"))) {
    add("error", "SSH_USER_PASSWORD must not contain a newline", "SSH_USER_PASSWORD");
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
    "  node tools/teslausb-config.js preflight CONFIG.conf",
    "  node tools/teslausb-config.js sanitize CONFIG.conf [SANITIZED.conf]",
    "",
    "Use '-' as an input or output path for stdin/stdout. Existing output files are never overwritten."
  ].join("\n");
}

function main(argv) {
  const [command, inputPath, outputPath] = argv;
  if (!command || !inputPath || !["generate", "preflight", "sanitize"].includes(command)) {
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
  decodeLiteral,
  generateConfig,
  parseConfig,
  preflightConfig,
  sanitizeConfig
};
