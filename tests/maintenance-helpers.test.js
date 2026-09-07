"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "..", "teslausb-www", "html", "index.html"), "utf8");
const inline = html.match(/<script>\s*([\s\S]*?)<\/script>/i)[1];
new vm.Script(inline, {filename: "index-inline.js"});
const start = inline.indexOf("// Advanced maintenance helpers:");
const end = inline.indexOf("// End advanced maintenance helpers.", start);
assert.ok(start >= 0 && end > start);
const source = inline.slice(start, end);

function makeElement(value = "") {
  return {
    value, textContent: "", disabled: false, open: false, selected: false,
    attributes: {}, style: {},
    setAttribute(name, value) { this.attributes[name] = value; },
    getAttribute(name) { return this.attributes[name] ?? null; },
    removeAttribute(name) { delete this.attributes[name]; },
    focus() { this.focused = true; },
    select() { this.selected = true; },
    setSelectionRange(start, end) { this.selectionRange = [start, end]; }
  };
}

function harness() {
  const elements = new Map();
  const document = {
    activeElement: makeElement(),
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, makeElement());
      return elements.get(id);
    }
  };
  const requests = [];
  class FakeRequest {
    constructor() { this.headers = {}; this.responseHeaders = {}; this.status = 0; requests.push(this); }
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader(name, value) { this.headers[name] = value; }
    getResponseHeader(name) { return this.responseHeaders[name] || null; }
    send() { this.sent = true; }
    abort() { this.aborted = true; this.onabort(); }
    respond({status = 200, type = "text/plain; charset=utf-8", truncated = "false", size = 123} = {}) {
      this.status = status;
      this.responseHeaders = {"Content-Type":type, "X-TeslaUSB-Truncated":truncated};
      this.response = {size};
      this.readyState = 4;
      this.onreadystatechange();
    }
  }
  const context = vm.createContext({
    document, navigator: {}, window: {location: {hostname: "teslausb.local"}},
    URL, XMLHttpRequest: FakeRequest, setTimeout,
    setResourceStatus(id, message, isError) {
      const element = document.getElementById(id);
      element.textContent = message;
      element.error = isError;
    },
    apiRequest: async () => ({schema_version:1, ssh:{service_state:"active", enabled_state:"enabled"}, logs:{}})
  });
  vm.runInContext(source, context);
  document.getElementById("maintenance-ssh-user").value = "root";
  document.getElementById("maintenance-ssh-host").value = "teslausb.local";
  document.getElementById("maintenance-ssh-port").value = "22";
  return {context, document, requests};
}

async function run() {
  const {context:c, document:d, requests} = harness();
  assert.equal(c.buildMaintenanceCommand("root", "TeslaUSB.local", "22", ""), "ssh -p 22 root@teslausb.local");
  assert.equal(c.buildMaintenanceCommand("pi", "198.51.100.42", "2222", "C:\\Users\\Example User\\.ssh\\maintenance"),
    "ssh -p 2222 -o IdentitiesOnly=yes -i 'C:\\Users\\Example User\\.ssh\\maintenance' pi@198.51.100.42");
  assert.equal(c.buildMaintenanceCommand("root", "[2001:db8::7]", 22, "/home/example/.ssh/maintenance"),
    "ssh -p 22 -o IdentitiesOnly=yes -i '/home/example/.ssh/maintenance' root@2001:db8::7");
  assert.equal(c.validatedMaintenanceHost("::1"), "::1");
  for (const username of ["", "-oProxyCommand=x", "root;id", "root@other", "$(id)", "a\nb", "a".repeat(33)]) {
    assert.throws(() => c.buildMaintenanceCommand(username, "teslausb.local", 22, ""), /username/);
  }
  for (const host of ["", "https://teslausb.local", "teslausb.local:22", "-oProxyCommand=x", "pi;id", "pi\nx", "$(id)", "host/", "a..b", "_bad.local", "999.1.2.3", "1.2.3", "01.2.3.4", "[:::]", "fe80::1%eth0"]) {
    assert.throws(() => c.buildMaintenanceCommand("root", host, 22, ""));
  }
  for (const port of [0, -1, 65536, "22;id", "0x16", "22.5", "", "022"]) {
    assert.throws(() => c.buildMaintenanceCommand("root", "teslausb.local", port, ""), /port/);
  }
  for (const key of ["~/.ssh/key", "relative/key", "\\\\server\\key", "//server/key", "C:/Users/O'Name/key", "/tmp/\"key\"", "/tmp/key\nvalue", "/tmp/$(id)", "/tmp/`id`", "/tmp/%PATH%", "/tmp/key;id", "/tmp/key|id", "/tmp/key&x"]) {
    assert.throws(() => c.buildMaintenanceCommand("root", "teslausb.local", 22, key), /local key path/);
  }
  for (const character of ["\u2018", "\u2019", "\u201a", "\u201b", "\u201c", "\u201d", "\u201e", "\u201f", "\u2028", "\u2029", "\u200b", "\u0085", "\n", "\t"]) {
    assert.throws(() => c.buildMaintenanceCommand("root", "teslausb.local", 22, "/tmp/" + character + "key"), /local key path/);
  }
  assert.throws(() => c.buildMaintenanceCommand("root", "teslausb.local", 22, "C:\\key\u2019 -oProxyCommand=calc \u2018x"), /local key path/);
  assert.ok(!c.buildMaintenanceCommand("root", "teslausb.local", 22, "").includes("IdentitiesOnly"));

  c.initializeMaintenance();
  assert.equal(d.getElementById("maintenance-ssh-host").value, "teslausb.local");
  c.window.location.hostname = "-oProxyCommand=bad";
  c.initializeMaintenance();
  assert.equal(d.getElementById("maintenance-ssh-host").value, "");
  assert.equal(d.getElementById("maintenance-copy").disabled, true);
  assert.equal(d.getElementById("maintenance-ssh-command").value, "");
  d.getElementById("maintenance-ssh-host").value = "teslausb.local";

  let clipboardText;
  c.navigator.clipboard = {writeText: async value => { clipboardText = value; }};
  assert.equal(await c.copyMaintenanceCommand(), true);
  assert.equal(clipboardText, "ssh -p 22 root@teslausb.local");
  assert.match(d.getElementById("maintenance-command-status").textContent, /copied/);
  assert.equal(d.activeElement.focused, true);
  let legacyCopies = 0;
  c.navigator.clipboard.writeText = async () => { throw new Error("insecure context"); };
  d.execCommand = command => { assert.equal(command, "copy"); legacyCopies++; return true; };
  assert.equal(await c.copyMaintenanceCommand(), true);
  assert.equal(legacyCopies, 1);
  assert.equal(d.getElementById("maintenance-ssh-command").selected, true);
  c.navigator.clipboard = undefined;
  d.execCommand = () => false;
  assert.equal(await c.copyMaintenanceCommand(), false);
  assert.match(d.getElementById("maintenance-command-status").textContent, /Ctrl\+C or Command\+C/);
  d.execCommand = () => { throw new Error("blocked"); };
  assert.equal(await c.copyMaintenanceCommand(), false);
  d.getElementById("maintenance-ssh-user").value = "root;bad";
  assert.equal(await c.copyMaintenanceCommand(), false);
  assert.equal(d.getElementById("maintenance-ssh-command").value, "");
  d.getElementById("maintenance-ssh-user").value = "root";

  assert.match(c.maintenanceSshStatusText({schema_version:1, ssh:{service_state:"active", enabled_state:"enabled"}}),
    /SSH service: active.*Login and port reachability are not verified/);
  assert.match(c.maintenanceSshStatusText({schema_version:1, ssh:{service_state:"<script>", enabled_state:"surprise"}}),
    /SSH service: unknown\. Startup: unknown/);
  assert.throws(() => c.maintenanceSshStatusText({schema_version:2, ssh:{}}), /not recognized/);
  assert.match(c.maintenanceHealthText({}), /health unavailable/);
  const health = {schema_version:1,
    storage:{backing:{available:true, total_bytes:500 * 1024 ** 3, free_bytes:80 * 1024 ** 3,
      cleanup_reserve_bytes:25 * 1024 ** 3, below_cleanup_reserve:false},
      mutable:{available:true, total_bytes:278 * 1024 ** 2, free_bytes:262 * 1024 ** 2}},
    read_only:{root:true, boot:null},
    snapshots:{available:true, scan_complete:true, last_completed:{name:"snap-000164", completed_at_utc:"2026-09-07T15:00:00+00:00"}},
    cleanup:{available:true, evidence:"release_attempt"},
    clock:{available:true, state:"waiting_for_network_time", last_verified_utc:null},
    recovery:{available:true, scan_complete:true, items:[{}], total_logical_bytes:400 * 1024 ** 3,
      total_allocated_bytes:80 * 1024 ** 3}};
  let healthText = c.maintenanceHealthText({health});
  assert.match(healthText, /80.0 GiB free of 500.0 GiB.*reserve: 25.0 GiB.*above reserve/);
  assert.match(healthText, /Mutable\/log storage: 262 MiB free of 278 MiB/);
  assert.match(healthText, /Recovery backups: 1 bundle;/);
  assert.match(healthText, /Live camera filesystem: not inspected/);
  assert.match(healthText, /root read-only; boot unknown/);
  assert.match(healthText, /snap-000164/);
  assert.match(healthText, /Cleanup attempt found; completion is not confirmed/);
  assert.match(healthText, /waiting for network time; last verified unknown/);
  assert.match(healthText, /400.0 GiB logical, 80.0 GiB reported allocation.*not reclaimable space/);
  health.snapshots.scan_complete = false;
  health.recovery.scan_complete = false;
  healthText = c.maintenanceHealthText({health});
  assert.doesNotMatch(healthText, /snap-000164|400.0 GiB/);
  assert.match(healthText, /inventory: unavailable or incomplete/);

  let apiCalls = 0;
  c.apiRequest = async (url, options) => {
    apiCalls++;
    assert.equal(url, "/api/v1/maintenance");
    assert.equal(options.timeout, 15000);
    return {schema_version:1, ssh:{service_state:"active", enabled_state:"enabled"}, logs:{diagnostics:{available:false, reason:"missing"}, setup:{available:true, size_bytes:10 * 1024 * 1024, truncated:true}}};
  };
  await c.refreshMaintenanceStatus();
  assert.equal(apiCalls, 0, "collapsed panels must not fetch status");
  d.getElementById("maintenance-panel").open = true;
  await c.refreshMaintenanceStatus();
  assert.equal(apiCalls, 1);
  assert.match(d.getElementById("maintenance-ssh-status").textContent, /SSH service: active/);
  assert.match(d.getElementById("maintenance-log-diagnostics").textContent, /No saved file/);
  assert.match(d.getElementById("maintenance-log-setup").textContent, /latest 8 MiB/);
  assert.match(d.getElementById("maintenance-health-status").textContent, /unavailable/);
  c.apiRequest = async () => { throw new Error("offline"); };
  await c.refreshMaintenanceStatus();
  assert.match(d.getElementById("maintenance-ssh-status").textContent, /SSH status unknown: refresh failed/);
  assert.doesNotMatch(d.getElementById("maintenance-ssh-status").textContent, /service: active/);
  assert.match(d.getElementById("maintenance-log-setup").textContent, /Availability unknown/);
  assert.match(d.getElementById("maintenance-health-status").textContent, /Health unknown: refresh failed/);
  assert.equal(d.getElementById("maintenance-refresh").disabled, false);

  let resolveOld;
  c.apiRequest = () => new Promise(resolve => { resolveOld = resolve; });
  const oldRefresh = c.refreshMaintenanceStatus();
  d.getElementById("maintenance-panel").open = false;
  c.maintenancePanelToggled(d.getElementById("maintenance-panel"));
  resolveOld({schema_version:1, ssh:{service_state:"active", enabled_state:"enabled"}});
  await oldRefresh;
  assert.doesNotMatch(d.getElementById("maintenance-ssh-status").textContent, /service: active/);
  assert.equal(d.getElementById("maintenance-refresh").disabled, false);

  for (const id of ["../secret", "__proto__", "constructor", "toString"]) {
    await assert.rejects(c.requestMaintenanceLog(id), /Unknown support log/);
  }
  let pending = c.requestMaintenanceLog("archiveloop");
  let request = requests.at(-1);
  assert.equal(request.method, "GET");
  assert.equal(request.url, "/api/v1/maintenance/logs/archiveloop");
  assert.equal(request.timeout, 15000);
  assert.equal(request.responseType, "blob");
  request.respond({truncated:"true", size:8 * 1024 * 1024});
  assert.equal((await pending).truncated, true);
  for (const fixture of [
    {response:{status:404}, error:/No saved log/},
    {response:{status:401}, error:/Sign in/},
    {response:{status:403}, error:/Sign in/},
    {response:{status:500}, error:/HTTP 500/},
    {response:{type:"text/html"}, error:/unexpected response/},
    {response:{type:"application/json"}, error:/unexpected response/},
    {response:{truncated:null}, error:/unexpected response/},
    {response:{size:8 * 1024 * 1024 + 1}, error:/safe download limit/}
  ]) {
    pending = c.requestMaintenanceLog("setup");
    request = requests.at(-1);
    request.respond(fixture.response);
    await assert.rejects(pending, fixture.error);
  }
  pending = c.requestMaintenanceLog("setup");
  request = requests.at(-1);
  request.onprogress({loaded:8 * 1024 * 1024 + 1});
  await assert.rejects(pending, /safe download limit/);
  assert.equal(request.aborted, true);
  for (const [event, error] of [["ontimeout", /timed out/], ["onerror", /Network error/], ["onabort", /cancelled/], ["onloadend", /Network request failed/]]) {
    pending = c.requestMaintenanceLog("maintenance");
    request = requests.at(-1);
    let settled = false;
    pending.then(() => { settled = true; }, () => { settled = true; });
    request.respond({status:0});
    await Promise.resolve();
    assert.equal(settled, false, "DONE/status zero must wait for the actual failure event");
    request[event]();
    request.onloadend();
    await assert.rejects(pending, error);
  }

  let saves = 0;
  c.saveMaintenanceLog = (filename, blob) => { assert.equal(filename, "teslausb-runtime-maintenance.log"); assert.ok(blob); saves++; };
  const downloadButton = d.getElementById("maintenance-download-maintenance");
  pending = c.downloadMaintenanceLog("maintenance", downloadButton);
  assert.equal(downloadButton.disabled, true);
  requests.at(-1).respond({status:500});
  await pending;
  assert.equal(saves, 0, "error pages must not be saved as logs");
  assert.equal(downloadButton.disabled, false);
  assert.match(d.getElementById("maintenance-download-status").textContent, /Could not download/);
  pending = c.downloadMaintenanceLog("maintenance", downloadButton);
  requests.at(-1).respond({truncated:"true"});
  await pending;
  assert.equal(saves, 1);
  assert.match(d.getElementById("maintenance-download-status").textContent, /Truncated.*first line may be partial/);

  let generations = 0;
  c.refreshdiagnostics = async () => { generations++; return true; };
  const generateButton = d.getElementById("maintenance-generate");
  await c.generateMaintenanceDiagnostics(generateButton);
  assert.equal(generations, 1);
  assert.match(d.getElementById("maintenance-download-status").textContent, /Fresh diagnostics generated/);
  d.getElementById("diagrefreshbtn").setAttribute("aria-busy", "true");
  await c.generateMaintenanceDiagnostics(generateButton);
  assert.equal(generations, 1);
  assert.match(d.getElementById("maintenance-download-status").textContent, /already being generated/);

  const initSource = inline.slice(inline.indexOf("function initialize()"), inline.indexOf("function updateTabAccessibility()"));
  assert.doesNotMatch(initSource, /refreshdiagnostics\(/, "page load must not generate diagnostics");
  assert.doesNotMatch(source, /setInterval|localStorage|type\s*=\s*["']file|\.innerHTML\s*=/);
  assert.match(html, /<details[^>]*id="maintenance-panel"[^>]*>/);
  assert.match(html, /<summary>Advanced maintenance<\/summary>/);
  assert.match(html, /id="maintenance-ssh-command"[^>]*readonly/);
  assert.match(html, /id="maintenance-command-status"[^>]*role="status"[^>]*aria-live="polite"/);
  assert.match(html, /\.content4\s*\{\s*overflow-y: auto;/);
  console.log("maintenance helper tests passed");
}

const testPromise = run();
if (require.main === module) {
  testPromise.catch(error => { console.error(error); process.exitCode = 1; });
}
module.exports = testPromise;
