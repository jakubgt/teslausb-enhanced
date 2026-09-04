"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const indexPath = path.join(__dirname, "..", "teslausb-www", "html", "index.html");
const html = fs.readFileSync(indexPath, "utf8");
const inlineMatch = html.match(/<script>\s*([\s\S]*?)<\/script>/i);
const diagnosticsHtml = fs.readFileSync(
  path.join(__dirname, "..", "teslausb-www", "html", "diagnostics.html"),
  "utf8");
const diagnosticsScript = diagnosticsHtml.match(/<script>\s*([\s\S]*?)<\/script>/i);

assert.ok(inlineMatch, "index.html should contain its inline JavaScript");
assert.ok(diagnosticsScript, "diagnostics.html should contain its inline JavaScript");

const inlineScript = inlineMatch[1];
new vm.Script(inlineScript, {filename: "index-inline.js"});
new vm.Script(diagnosticsScript[1], {filename: "diagnostics-inline.js"});

function extractBetween(startMarker, endMarker) {
  const start = inlineScript.indexOf(startMarker);
  const end = inlineScript.indexOf(endMarker, start);
  assert.notEqual(start, -1, `missing ${startMarker}`);
  assert.notEqual(end, -1, `missing ${endMarker}`);
  return inlineScript.slice(start, end);
}

const context = vm.createContext({});
vm.runInContext(
  extractBetween("function cgiRequestErrorMessage", "function clearMessageAfter"),
  context
);
vm.runInContext(
  extractBetween("function parseWifiStrength", "async function toggledrivesfunc"),
  context
);
vm.runInContext(
  extractBetween("function spaceString", "const longDateOpts"),
  context
);
assert.equal(context.spaceString(37 * 1024 ** 3), "37 GiB");
assert.equal(context.spaceString(512 * 1024 ** 2), "0.5 GiB");
assert.equal(context.spaceString(64 * 1024 ** 2), "64 MiB");
context.spaceString = (bytes) => `${bytes} bytes`;
vm.runInContext(
  extractBetween("function archiveStatusFromSystemStatus", "function renderArchiveStatus"),
  context
);
vm.runInContext(
  extractBetween("function renderEncryptedClipStatus", "var statusvals"),
  context
);
vm.runInContext(
  extractBetween("function parseVideoListResponse", "readfile({url:'/api/v1/videos'"),
  context
);

assert.equal(context.cgiRequestErrorMessage(500, "Server Error"), "HTTP 500 Server Error");
assert.equal(context.cgiRequestErrorMessage(0, ""), "Network request failed");

assert.equal(context.parseWifiStrength("35/70"), 0.5);
assert.equal(context.parseWifiStrength("70 / 70"), 1);
assert.equal(context.parseWifiStrength("90/70"), 1);
assert.equal(context.parseWifiStrength("-1"), 0);
assert.equal(context.parseWifiStrength("1/0"), null);
assert.equal(context.parseWifiStrength(""), null);
assert.equal(context.parseWifiStrength("globalThis.compromised = true"), null);
assert.equal(context.compromised, undefined);

assert.equal(
  context.cameraDriveStatusText({camera_drive_state: "connected"}),
  "Camera drive: connected to host");
assert.equal(
  context.cameraDriveStatusText({camera_drive_state: "paused", drives_active: "yes"}),
  "Camera drive: paused; camera image detached");
assert.equal(
  context.cameraDriveStatusText({camera_drive_state: "prepared", drives_active: "yes"}),
  "Camera drive: prepared, not connected");
assert.equal(
  context.cameraDriveStatusText({camera_drive_state: "suspended"}),
  "Camera drive: host suspended USB");
assert.equal(
  context.cameraDriveStatusText({camera_drive_state: "disconnected"}),
  "Camera drive: waiting for a USB host");
for (const incompleteStatus of [undefined, {drives_active: "yes"},
  {camera_drive_state: "toString"}, {camera_drive_state: "future-state"}]) {
  assert.equal(context.cameraDriveStatusText(incompleteStatus),
    "Camera drive: connection status unavailable");
}

const archiveView = context.archiveStatusView({
  archive_status: {
    available: true,
    schema_version: 1,
    last_result: "running",
    last_started: "2026-08-02T12:00:00Z",
    last_finished: "",
    pending_files: 3,
    pending_bytes: 300,
    transferred_files: 2,
    transferred_bytes: 200,
    message: "Uploading"
  }
});
assert.equal(archiveView.visible, true);
assert.equal(archiveView.state, "running");
assert.equal(archiveView.progressMax, 500);
assert.equal(archiveView.progressValue, 200);
assert.match(archiveView.summary, /2 of 5 files/);
assert.equal(
  context.archiveStatusView({archive_status: {available: false}}).state,
  "unavailable");

const encryptedView = context.encryptedClipStatusView({
  encrypted_clips: {
    available: true,
    schema_version: 1,
    detected: true,
    locations: 1,
    message: "server-provided text is not rendered"
  }
});
assert.equal(encryptedView.visible, true);
assert.match(encryptedView.message, /leaves these recordings untouched/);
assert.doesNotMatch(encryptedView.message, /server-provided/);
assert.equal(
  context.encryptedClipStatusView({
    encrypted_clips: {available: true, schema_version: 1, detected: false}
  }).visible,
  false);
assert.equal(
  context.encryptedClipStatusView({
    encrypted_clips: {available: false, schema_version: 1, detected: true}
  }).visible,
  false);
assert.equal(
  context.encryptedClipStatusView({
    encrypted_clips: {available: true, schema_version: 2, detected: true}
  }).visible,
  true,
  "a positive detection remains fail-safe across status schema updates");

const encryptedMessage = {textContent: ""};
const encryptedContainer = {
  hidden: true,
  querySelector(selector) {
    assert.equal(selector, ".status_encrypted_message");
    return encryptedMessage;
  }
};
context.document = {
  querySelector(selector) {
    assert.equal(selector, ".status_encrypted");
    return encryptedContainer;
  }
};
context.renderEncryptedClipStatus({
  encrypted_clips: {available: true, schema_version: 1, detected: true}
});
assert.equal(encryptedContainer.hidden, false);
assert.match(encryptedMessage.textContent, /cannot archive or play/);
context.renderEncryptedClipStatus({
  encrypted_clips: {available: true, schema_version: 1, detected: false}
});
assert.equal(encryptedContainer.hidden, true);
assert.equal(encryptedMessage.textContent, "");

assert.deepEqual(
  Array.from(context.parseVideoListResponse('{"videos":["SavedClips/a/front.mp4"]}')),
  ["SavedClips/a/front.mp4"]);
assert.throws(
  () => context.parseVideoListResponse('{"videos":"not-an-array"}'),
  /unexpected format/);

assert.match(
  inlineScript,
  /readconfig\(\);\s*initialize\(\);\s*function parseVideoListResponse/,
  "page initialization must not wait for the video-list request"
);
assert.doesNotMatch(inlineScript, /callcgi\(['"]cgi-bin\//, "mutations must not call legacy CGI routes");
assert.doesNotMatch(html, /cgi-bin\//, "the bundled dashboard must use versioned API routes");
assert.match(inlineScript, /callcgi\('\/api\/v1\/actions\/drives\/repair', \{timeout:60000\}\)/);
assert.match(inlineScript, /Confirm USB gadget repair/);
assert.match(html, /id="repairgadgettext" role="status" aria-live="polite"/);
assert.match(html, /class="status_encrypted" hidden role="alert"/);
assert.match(inlineScript, /renderEncryptedClipStatus\(statusvals\)/);
assert.match(inlineScript, /drivesdiv\.innerText = cameraDriveStatusText\(statusvals\)/);
assert.doesNotMatch(inlineScript, /Drives: visible to host/);
assert.match(inlineScript, /fetch\('\/api\/v1\/speed-test\?' \+ SPEED_TEST_SECONDS/);
assert.match(diagnosticsHtml, /fetchWithTimeout\("\/api\/v1\/actions\/diagnostics",\s*\{\s*method: "POST"/);
assert.match(diagnosticsHtml, /"X-TeslaUSB-Request": "1"/);
assert.doesNotMatch(diagnosticsHtml, /src=["']cgi-bin\/diagnose\.sh/);

class FakeXMLHttpRequest {
  static nextResponse = null;

  constructor() {
    FakeXMLHttpRequest.lastInstance = this;
    this.headers = {};
  }

  open(method, url) {
    this.method = method;
    this.url = url;
  }

  setRequestHeader(name, value) {
    this.headers[name] = value;
  }

  send() {
    const response = FakeXMLHttpRequest.nextResponse;
    Object.assign(this, response);
    if (response.event === "timeout") {
      this.ontimeout();
      return;
    }
    if (response.event === "abort") {
      this.onabort();
      return;
    }
    this.readyState = 4;
    this.onreadystatechange();
    if (response.event === "error") {
      this.onerror();
    }
  }
}

context.XMLHttpRequest = FakeXMLHttpRequest;

async function run() {
  FakeXMLHttpRequest.nextResponse = {
    status: 200,
    statusText: "OK",
    responseText: '{"ok":true,"message":"done"}'
  };
  const result = await context.callcgi("/api/v1/actions/sync");
  assert.equal(result.ok, true);
  assert.equal(result.message, "done");
  assert.equal(FakeXMLHttpRequest.lastInstance.method, "POST");
  assert.equal(FakeXMLHttpRequest.lastInstance.url, "/api/v1/actions/sync");
  assert.equal(FakeXMLHttpRequest.lastInstance.headers["X-TeslaUSB-Request"], "1");
  assert.equal(FakeXMLHttpRequest.lastInstance.headers.Accept, "application/json");
  assert.equal(FakeXMLHttpRequest.lastInstance.timeout, 30000);

  FakeXMLHttpRequest.nextResponse = {
    status: 500,
    statusText: "Server Error",
    responseText: '{"ok":false,"error":"failed"}'
  };
  await assert.rejects(context.callcgi("/api/v1/actions/sync"), /failed \(HTTP 500\)/);

  FakeXMLHttpRequest.nextResponse = {
    status: 0,
    statusText: "",
    responseText: "",
    event: "error"
  };
  await assert.rejects(context.callcgi("/api/v1/actions/sync"), /Network request failed/);

  FakeXMLHttpRequest.nextResponse = {event: "timeout"};
  await assert.rejects(context.callcgi("/api/v1/actions/sync"), /Request timed out/);

  FakeXMLHttpRequest.nextResponse = {
    status: 200,
    statusText: "OK",
    responseText: "not json"
  };
  await assert.rejects(
    context.apiRequest("/api/v1/status"),
    /invalid JSON response/);

  console.log("index helper tests passed");
}

const testPromise = run();
if (require.main === module) {
  testPromise.catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

module.exports = testPromise;
