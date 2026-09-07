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
  extractBetween("function readfile({", "function readfilePromise"),
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
  extractBetween("// Recording library helpers.", "// End recording library helpers."),
  context
);
vm.runInContext(extractBetween("function cachebustingurl", "function isElementVisible"), context);
assert.equal(new URL(context.cachebustingurl("/api/v1/videos?day=latest"), "http://example.test").searchParams.get("day"), "latest");
const baseControlsOpacity = html.search(/#videocontrols\s*\{\s*opacity:\s*0\.0/);
assert.ok(baseControlsOpacity >= 0 && html.indexOf("#videocontrols { opacity: 0.72; }") > baseControlsOpacity,
  "the touch opacity override must follow the base opacity rule");

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
  Array.from(context.parseVideoListResponse(
    '{"videos":["SavedClips/2026-09-07_09-00-00/front.mp4"]}')),
  ["SavedClips/2026-09-07_09-00-00/front.mp4"]);
assert.throws(
  () => context.parseVideoListResponse('{"videos":"not-an-array"}'),
  /unexpected format/);
assert.throws(
  () => context.parseVideoListResponse('{"videos":[null]}'),
  /unexpected format/);
assert.deepEqual(
  Array.from(context.parseVideoListResponse(JSON.stringify({videos: [
    "SavedClips/event",
    "TeslaTrackMode/2026-09-07-lap.mp4",
    "SavedClips/2026-09-07/",
    "SavedClips/2026-09-07/../front.mp4",
    "SavedClips/2026-09-07/..",
    "SavedClips/../front.mp4",
    "SavedClips/__proto__/front.mp4",
    "__proto__/2026-09-07/front.mp4",
    "OtherClips/2026-09-07/front.mp4",
    "RecentClips/2026-09-07/2026-09-07_09-00-00-front.mp4",
    "SentryClips/2026-09-07_09-00-00/event.json"
  ]}))),
  ["RecentClips/2026-09-07/2026-09-07_09-00-00-front.mp4",
    "SentryClips/2026-09-07_09-00-00/event.json"],
  "unsupported or malformed index paths must not abort the recording viewer");
assert.match(context.videoListErrorMessage(new Error("Request timed out")),
  /longer than 30 seconds.*Refresh recordings to retry/);
assert.match(context.videoListErrorMessage(new Error("Network error")),
  /Network error.*Check your connection to TeslaUSB/);
assert.match(context.videoListErrorMessage(new Error("HTTP 503 Service Unavailable")),
  /HTTP 503 Service Unavailable.*Wait a moment.*Refresh recordings to retry/);
assert.doesNotMatch(context.videoListErrorMessage(new Error("Request cancelled")),
  /Check your connection/);

assert.match(
  inlineScript,
  /readconfig\(\);\s*initialize\(\);\s*\/\/ Recording library helpers\./,
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
    this.status = 0;
    this.statusText = "";
    this.responseText = "";
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
    // Real failed XHRs report DONE/status zero before timeout/error/abort,
    // followed by loadend. A partial response must not change this ordering.
    this.readyState = 4;
    this.onreadystatechange();
    if (!response.deferTerminal) this.finish(response.event);
  }

  finish(event) {
    if (event && this[`on${event}`]) this[`on${event}`]();
    if (this.onloadend) this.onloadend();
  }
}

context.XMLHttpRequest = FakeXMLHttpRequest;
context.log = () => {};
context.readyState = (state) => state;
context.cachebustingurl = (url) => url;
context.resourceStatusId = () => undefined;
context.finishInitialVideoListLoad = () => {};
const resourceUpdates = [];
context.setResourceStatus = (...args) => resourceUpdates.push(args);

function recordingHarness() {
  const elements = new Map(), requests = [], timers = new Map();
  let timerId = 0;
  function node() {
    return {textContent:"", value:"0", clientHeight:1, attributes:{}, style:{}, childNodes:[],
      classList:{add() {}, remove() {}, contains() { return false; }},
      setAttribute(name, value) { this.attributes[name] = value; },
      removeAttribute(name) { delete this.attributes[name]; },
      get lastChild() { return this.childNodes.at(-1) || null; },
      get childElementCount() { return this.childNodes.length; },
      appendChild(child) {
        if (child.parentNode) child.parentNode.childNodes.splice(child.parentNode.childNodes.indexOf(child), 1);
        this.childNodes.push(child); child.parentNode = this; return child;
      },
      append(...children) { children.forEach(child => this.appendChild(child)); },
      replaceChildren(...children) {
        this.childNodes.forEach(child => { child.parentNode = null; }); this.childNodes = [];
        this.append(...children);
      }};
  }
  const get = id => { if (!elements.has(id)) elements.set(id, node()); return elements.get(id); };
  get("tab7").checked = true;
  for (const category of ["RecentClips", "SavedClips", "SentryClips"]) {
    get(category).parentElement = {style:{}, getBoundingClientRect() { return {left:0}; }};
  }
  const gate = vm.createContext({
    document:{querySelector:get, getElementById:get, querySelectorAll:() => [], createElement:node, body:{clientWidth:1000}},
    isElementVisible:() => true,
    setTimeout:(callback, delay) => { timers.set(++timerId, {callback, delay}); return timerId; },
    clearTimeout:id => timers.delete(id),
    readfile:options => requests.push(options),
    setViewerStatus:(message, error) => { get("viewerstatus").textContent = message; get("viewerstatus").error = error; },
    getMaintenanceStatus:() => Promise.resolve({health:{snapshots:{available:false}}}),
    localStorageGet:() => "oldest", log:() => {}, WORK_AROUND_WEBKIT_QUIRKS:false,
    videos:{}, currentsequence:undefined, videoelems:[], canvaselems:[],
    makeDropdownItem:(group, sequence) => { const result = node(); result.textContent = sequence; return result; }
  });
  gate.VideoSequence = class {
    constructor(group, name) { this.sequencegroup = group; this.sequencename = name; this.segments = []; this.jsonfile = []; this.currentsegmentidx = -1; this.playing = false; }
    getSegmentByName(name) {
      let segment = this.segments.find(item => item.datetime === name);
      if (!segment) {
        segment = {datetime:name, addVideo(filename) { this.front = filename; }};
        this.segments.push(segment);
      }
      return segment;
    }
    getSegmentByIndex(index) { return this.segments[index]; }
    currentSegmentIdx() { return this.currentsegmentidx; }
    length() { return this.segments.length; }
    initialize() {}
    isPlaying() { return this.playing; }
    select() { gate.currentsequence = this; this.currentsegmentidx = 0; }
    seekTo(position) { get("position").value = position; this.currentsegmentidx = Math.floor(position / 60000); }
    pause() { this.playing = false; }
    play() { this.playing = true; }
  };
  vm.runInContext(extractBetween("var statusvals;", "var config;"), gate);
  vm.runInContext(extractBetween("function updateTabAccessibility()", "function initializeAccessibility()"), gate);
  vm.runInContext(extractBetween("// Recording library helpers.", "// End recording library helpers."), gate);
  return {gate, requests, timers, get};
}

function recordingPage(day = "2026-09-07", videos = []) {
  return JSON.stringify({videos, available_days:["2026-09-07", "2026-09-06"], selected_day:day,
    generated_at:"2026-09-07T15:00:00Z", newest_recording:videos.length ? day + "_09-00-00" : null});
}

function mediaHarness() {
  const harness = recordingHarness();
  const {gate, get} = harness;
  Object.assign(gate, {isFirefox:false, isWebkit:false, timeString:String,
    showCurrentSegment:() => {}, showCurrentTime:() => {}, showDebugInfo:() => {},
    freezeVideoElems:() => {}, unfreezeVideoElems:() => {}, videoError:() => "fixture error",
    cachebustingurl:url => url + "?stable-fixture", playErrors:[]});
  gate.log = error => gate.playErrors.push(error);
  vm.runInContext(extractBetween("// Every source assignment owns", "var ro = new ResizeObserver"), gate);
  vm.runInContext(extractBetween("class VideoSequence", "var videos={};"), gate);
  vm.runInContext("this.RealSequence = VideoSequence", gate);
  for (const method of ["onMapResize", "onTickResize", "showSentryLocation"])
    gate.RealSequence.prototype[method] = () => {};
  gate.videoelems = Array.from({length:6}, (_, index) => {
    const attributes = {};
    return {id:"angle" + index, attributes, currentTime:0, duration:NaN, readyState:0,
      muted:index % 2 === 0, volume:(index + 1) / 10, playbackRate:1.25, defaultPlaybackRate:1,
      paused:true, ended:false, style:{}, loads:0, plays:0,
      get src() { return attributes.src || ""; }, set src(value) { attributes.src = value; },
      getAttribute(name) { return attributes[name] ?? null; },
      setAttribute(name, value) { attributes[name] = String(value); },
      removeAttribute(name) { delete attributes[name]; },
      pause() { this.paused = true; },
      play() { this.paused = false; this.plays++; return Promise.resolve(); },
      load() { this.loads++; this.currentTime = 0; this.duration = NaN; this.readyState = 0; this.playbackRate = this.defaultPlaybackRate; },
      metadata() { this.duration = 50 + index; this.readyState = 1; if (this.ondurationchange) this.ondurationchange({target:this}); }
    };
  });
  const day = "2026-09-07";
  const files = ["left_repeater", "left_pillar", "front", "right_repeater", "right_pillar", "back"]
    .map(angle => `RecentClips/${day}/${day}_09-00-00-${angle}.mp4`);
  harness.files = files;
  harness.initialize = async () => {
    gate.loadRecordings("latest");
    await harness.requests[0].callback(recordingPage(day, files));
    gate.videoelems.forEach(video => video.metadata());
    gate.currentsequence.pause();
    get("position").value = 23456;
    gate.videoelems.forEach((video, index) => { video.currentTime = 7.123 + index / 10; video.playbackRate = 1.25; });
    gate.statusRequestInFlight = false;
  };
  harness.state = () => gate.videoelems.map(video => ({src:video.getAttribute("src"), currentTime:video.currentTime,
    muted:video.muted, volume:video.volume, playbackRate:video.playbackRate, defaultPlaybackRate:video.defaultPlaybackRate}));
  return harness;
}

async function testMediaSuspension() {
  for (const outcome of ["success", "timeout", "invalid JSON", "metadata timeout", "metadata rejection"]) {
    const h = mediaHarness();
    const {gate, get, requests, timers} = h;
    await h.initialize();
    const sequence = gate.currentsequence, original = h.state();
    const oldCallbacks = gate.videoelems.map(video => [video.ondurationchange, video.onended, video.onerror]);
    let resolveMetadata, rejectMetadata;
    gate.getMaintenanceStatus = () => new Promise((resolve, reject) => { resolveMetadata = resolve; rejectMetadata = reject; });
    gate.statusRequestInFlight = true;
    const before = requests.length;
    assert.equal(gate.loadRecordings(), true);
    assert.match(get("viewerstatus").textContent, /car recording is unaffected/);
    assert.equal(requests.length, before, "existing status request remains serialized");
    assert.ok(gate.videoelems.every(video => !video.src && video.paused), "release media BEFORE waiting for status");
    for (const id of ["position", "playpause", "skipback", "skipforward", "recording-day", "recording-refresh"])
      assert.equal(get(id).disabled, true);
    assert.equal(gate.loadRecordings(), false);
    oldCallbacks.forEach((callbacks, index) => callbacks.forEach(callback => callback && callback({target:gate.videoelems[index]})));
    assert.equal(gate.currentsequence, sequence, "disposed media events must not advance selection");
    gate.statusRequestInFlight = false;
    const [waitId, waitTimer] = [...timers].find(([, timer]) => timer.delay === 100);
    timers.delete(waitId); waitTimer.callback();
    const list = requests.at(-1);
    const completion = list.callback(outcome === "invalid JSON" ? "invalid" : recordingPage("2026-09-07", h.files),
      null, outcome === "timeout" ? new Error("Request timed out") : null);
    await list.callback(null, null, new Error("duplicate callback"));
    if (!["timeout", "invalid JSON"].includes(outcome)) {
      assert.ok(gate.videoelems.every(video => !video.src), "metadata must finish BEFORE streams restart");
      assert.equal(get("recording-refresh").disabled, true);
      if (outcome === "metadata timeout") {
        const [id, timer] = [...timers].find(([, entry]) => entry.delay === 16000);
        timers.delete(id); timer.callback();
      } else if (outcome === "metadata rejection") rejectMetadata(new Error("unavailable"));
      else resolveMetadata({health:{snapshots:{available:false}}});
    }
    await completion;
    assert.equal(gate.currentsequence, sequence);
    assert.deepEqual(gate.videoelems.map(video => video.getAttribute("src")), original.map(item => item.src));
    const statusBeforeMetadata = get("viewerstatus").textContent;
    gate.videoelems.forEach(video => { video.metadata(); video.metadata(); });
    assert.deepEqual(h.state(), original, outcome + ": exact positions/audio/rates survive source reload");
    assert.ok(gate.videoelems.every(video => video.paused), "paused must not become autoplay");
    assert.equal(sequence.getSegmentByIndex(0).activevideoelems.length, 6, "duplicate duration events are ignored");
    assert.equal(get("position").value, 23456, "short-clip corrected timeline remains distinct from media seconds");
    assert.equal(get("viewerstatus").textContent, statusBeforeMetadata, "media readiness must not hide a list error");
    assert.equal(get("recording-refresh").disabled, false);
    if (outcome === "metadata timeout") {
      resolveMetadata({health:{snapshots:{available:true, scan_complete:true, last_completed:{name:"snap-000999"}}}});
      await Promise.resolve();
      assert.doesNotMatch(get("recording-freshness").textContent, /snap-000999/, "late metadata is disposed");
    }
  }
}

async function testMediaRestoreRaces() {
  const h = mediaHarness();
  const {gate, requests, get, timers} = h;
  await h.initialize();
  const original = h.state();
  gate.currentsequence.play();
  gate.videoelems.forEach(video => { video.paused = false; });
  gate.loadRecordings();
  await requests.at(-1).callback(recordingPage("2026-09-07", h.files));
  const stale = gate.videoelems[0].ondurationchange;
  gate.statusRequestInFlight = false;
  gate.loadRecordings(); // first restoration has not received metadata yet
  await requests.at(-1).callback(recordingPage("2026-09-07", h.files));
  stale({target:gate.videoelems[0]});
  gate.videoelems.forEach(video => video.metadata());
  assert.deepEqual(h.state(), original, "second refresh inherits pending exact seek state, not reset zero");
  assert.ok(gate.videoelems.every(video => !video.paused), "restore prior play intent and participating angles");

  gate.statusRequestInFlight = false;
  gate.loadRecordings();
  await requests.at(-1).callback(recordingPage("2026-09-07", h.files));
  gate.videoelems.slice(0, 5).forEach(video => video.metadata());
  gate.videoelems[5].onerror({target:gate.videoelems[5]});
  const segment = gate.currentsequence.getSegmentByIndex(0);
  assert.equal(segment.readytoplay, true, "one unavailable angle must not strand five restored angles");
  assert.equal(segment.activevideoelems.length, 5);

  gate.statusRequestInFlight = false;
  gate.loadRecordings();
  await requests.at(-1).callback(recordingPage("2026-09-07", h.files));
  const [id, timer] = [...timers].find(([, entry]) => entry.delay === 20000);
  timers.delete(id); timer.callback();
  assert.ok(gate.videoelems.every(video => !video.src), "failed bounded restore releases its downloads");
  assert.match(get("viewerstatus").textContent, /Press Play to retry/);
  assert.equal(segment.mediaRestore.stalled, true);
  gate.currentsequence.play();
  assert.ok(gate.videoelems.slice(0, 5).every(video => video.src), "Play directly retries saved sources");
  gate.videoelems.slice(0, 5).forEach(video => video.metadata());
  assert.deepEqual(h.state().slice(0, 5), original.slice(0, 5));
  gate.statusRequestInFlight = false;
  gate.loadRecordings();
  await requests.at(-1).callback(recordingPage("2026-09-07", h.files));
  const [retryId, retryTimer] = [...timers].find(([, entry]) => entry.delay === 20000);
  timers.delete(retryId); retryTimer.callback();
  gate.currentsequence.seekTo(19000);
  gate.currentsequence.play();
  assert.ok(gate.videoelems.slice(0, 5).every(video => video.src), "seek then Play retries sources after a bounded restore failure");
  gate.videoelems.slice(0, 5).forEach(video => video.metadata());
  assert.deepEqual(h.state().slice(0, 5), original.slice(0, 5).map(state => ({...state, currentTime:19})));

  gate.statusRequestInFlight = false;
  let finishMetadata;
  gate.getMaintenanceStatus = () => new Promise(resolve => { finishMetadata = resolve; });
  gate.loadRecordings("2026-09-06");
  const older = h.files.map(file => file.replaceAll("2026-09-07", "2026-09-06"));
  const completion = requests.at(-1).callback(recordingPage("2026-09-06", older));
  assert.equal(gate.currentsequence.sequencename, "2026-09-07");
  assert.ok(gate.videoelems.every(video => !video.src));
  finishMetadata(null); await completion;
  assert.equal(gate.currentsequence.sequencename, "2026-09-06");
  assert.ok(gate.videoelems.every(video => video.src.includes("2026-09-06")));
  gate.videoelems.forEach(video => video.metadata());
  gate.statusRequestInFlight = false;
  gate.getMaintenanceStatus = () => Promise.resolve(null);
  gate.loadRecordings("2026-09-06");
  await requests.at(-1).callback(recordingPage("2026-09-06", []));
  assert.equal(gate.currentsequence, undefined);
  assert.ok(gate.videoelems.every(video => !video.src), "empty successful day must not restore obsolete media");
}

async function testMediaPlayPromiseOwnership() {
  const h = mediaHarness();
  await h.initialize();
  const {gate, get} = h, video = gate.videoelems[0];
  for (const [name, disposed, expected] of [["AbortError", true, false], ["NotAllowedError", true, false],
    ["AbortError", false, true], ["NotAllowedError", false, true]]) {
    let reject;
    video.teslausbMediaOwner = {active:true, libraryAbort:false};
    video.play = () => new Promise((resolve, failed) => { reject = failed; });
    get("viewerstatus").textContent = "newer status";
    gate.playVideoSafely(video);
    if (disposed) gate.releaseVideoSource(video, true);
    reject(Object.assign(new Error("fixture failure"), {name}));
    await Promise.resolve();
    assert.equal(get("viewerstatus").textContent.includes("Playback could not start"), expected,
      "only current-source errors may change the viewer status");
  }
}

async function testMediaRestoreRemapsAndUserSeek() {
  const h = mediaHarness();
  const {gate, get, requests} = h;
  const previousFiles = h.files.map(file => file.replaceAll("09-00-00", "08-00-00"));
  gate.loadRecordings("latest");
  await requests[0].callback(recordingPage("2026-09-07", [...previousFiles, ...h.files]));
  gate.videoelems.forEach(video => video.metadata());
  gate.currentsequence.seekTo(83456);
  gate.videoelems.forEach(video => video.metadata());
  get("position").value = 83456;
  gate.videoelems.forEach((video, index) => { video.currentTime = 7.125 + index / 10; });
  const original = h.state();
  gate.statusRequestInFlight = false;
  gate.loadRecordings();
  await requests.at(-1).callback(recordingPage("2026-09-07", h.files));
  gate.videoelems.forEach(video => video.metadata());
  assert.equal(gate.currentsequence.currentSegmentIdx(), 0);
  assert.equal(get("position").value, 23456, "retired earlier clips remap the timeline without changing camera seconds");
  assert.deepEqual(h.state(), original);
  gate.statusRequestInFlight = false;
  gate.loadRecordings();
  await requests.at(-1).callback(recordingPage("2026-09-07", h.files));
  gate.currentsequence.seekTo(31000); // user input after list completion but before media readiness
  gate.videoelems.forEach(video => video.metadata());
  assert.ok(gate.videoelems.every(video => video.currentTime === 31), "a newer user seek wins over pending restore positions");
  const staleRestore = gate.suspendRecordingMedia();
  staleRestore.disposed = true;
  gate.restoreRecordingMedia(staleRestore);
  assert.ok(gate.videoelems.every(video => !video.src), "disposed transaction must not restore sources");
}

function selectViewerTab(harness, selected) {
  harness.get("tab7").checked = selected;
  harness.gate.updateTabAccessibility();
}

async function testViewerTabSuspension() {
  for (const playing of [false, true]) {
    const h = mediaHarness();
    const {gate, get, requests, timers} = h;
    await h.initialize();
    if (playing) {
      gate.currentsequence.play();
      gate.videoelems.forEach(video => { video.paused = false; });
    }
    const original = h.state(), requestCount = requests.length;
    const sequence = gate.currentsequence;
    const oldCallbacks = gate.videoelems.map(video => [video.ondurationchange, video.onended, video.onerror]);
    selectViewerTab(h, false);
    const saved = gate.viewerTabSuspension;
    assert.ok(saved, "tab change saves viewer state");
    assert.equal(saved.wasPlaying, playing);
    assert.ok(gate.videoelems.every(video => !video.src && video.paused), "Tools must have no attached viewer streams");
    selectViewerTab(h, false);
    assert.equal(gate.viewerTabSuspension, saved, "repeated navigation notification must not replace saved state with zero");
    oldCallbacks.forEach((callbacks, index) => callbacks.forEach(callback => callback && callback({target:gate.videoelems[index]})));
    assert.equal(gate.currentsequence, sequence);
    assert.equal(requests.length, requestCount, "tab suspension adds no network requests");
    selectViewerTab(h, true);
    assert.equal(gate.viewerTabSuspension, undefined);
    assert.equal(saved.disposed, true, "consuming a tab transaction does not dispose its new media-source owner");
    const reloads = gate.videoelems.map(video => video.loads);
    selectViewerTab(h, true);
    assert.deepEqual(gate.videoelems.map(video => video.loads), reloads, "return consumes saved state only once");
    assert.ok([...timers.values()].some(timer => timer.delay === 20000));
    selectViewerTab(h, false); // leave again before any restored metadata arrives
    assert.ok(![...timers.values()].some(timer => timer.delay === 20000), "leaving cancels the restoration watchdog");
    assert.ok(gate.videoelems.every(video => !video.src && video.paused));
    selectViewerTab(h, true);
    gate.videoelems.forEach(video => video.metadata());
    assert.deepEqual(h.state(), original, "rapid return/leave preserves pending nonzero camera times");
    assert.equal(get("position").value, 23456);
    assert.ok(gate.videoelems.every(video => video.paused !== playing));
    assert.equal(gate.currentsequence.isPlaying(), playing);
  }
}

async function testViewerTabRefreshRaces() {
  for (const outcome of ["unchanged", "new day", "timeout", "invalid JSON", "return before completion"]) {
    const h = mediaHarness();
    const {gate, requests, get} = h;
    await h.initialize();
    gate.currentsequence.play();
    gate.videoelems.forEach(video => { video.paused = false; });
    const original = h.state();
    const oldSequence = gate.currentsequence;
    const newDay = outcome === "new day";
    const day = newDay ? "2026-09-06" : "2026-09-07";
    const files = newDay ? h.files.map(file => file.replaceAll("2026-09-07", day)) : h.files;
    gate.loadRecordings(newDay ? day : "latest");
    const list = requests.at(-1);
    selectViewerTab(h, false);
    assert.ok(gate.videoelems.every(video => !video.src));
    let resolveMetadata;
    gate.getMaintenanceStatus = () => new Promise(resolve => { resolveMetadata = resolve; });
    const completion = list.callback(outcome === "invalid JSON" ? "invalid" : recordingPage(day, files),
      null, outcome === "timeout" ? new Error("Request timed out") : null);
    if (resolveMetadata) {
      assert.ok(gate.videoelems.every(video => !video.src), "media stays detached during metadata wait");
      if (outcome === "return before completion") {
        selectViewerTab(h, true);
        assert.ok(gate.videoelems.every(video => !video.src), "return must not race the in-flight library transaction");
      }
      resolveMetadata(null);
    }
    await completion;
    assert.equal(gate.initialVideoListLoading, false, "transaction always releases the status gate");
    assert.equal(gate.recordingLibrary.inFlight, false);
    assert.equal(get("recording-refresh").disabled, false);
    if (outcome !== "return before completion") {
      assert.ok(gate.videoelems.every(video => !video.src && video.paused), "completion in Tools must not attach or autoplay media");
      selectViewerTab(h, true);
    }
    gate.videoelems.forEach(video => video.metadata());
    if (newDay) {
      assert.notEqual(gate.currentsequence, oldSequence);
      assert.ok(gate.videoelems.every(video => video.src.includes(day) && video.paused));
    } else {
      assert.equal(gate.currentsequence, oldSequence);
      assert.deepEqual(h.state(), original);
      assert.ok(gate.videoelems.every(video => !video.paused));
    }
  }
}

async function testInitialLibraryAwayFromViewer() {
  for (const anotherRefresh of [false, true]) {
    const h = mediaHarness();
    const {gate, get, requests} = h;
    selectViewerTab(h, false);
    gate.loadRecordings("latest");
    await requests[0].callback(recordingPage("2026-09-07", h.files));
    assert.ok(gate.viewerDeferredSelection);
    assert.ok(gate.videoelems.every(video => !video.src));
    assert.equal(gate.initialVideoListLoading, false);
    assert.equal(requests.at(-1).url, "/api/v1/status", "initial off-Viewer list does not freeze health/status");
    if (anotherRefresh) {
      gate.statusRequestInFlight = false;
      gate.loadRecordings();
      await requests.at(-1).callback(recordingPage("2026-09-07", h.files));
      assert.ok(gate.videoelems.every(video => !video.src));
    }
    selectViewerTab(h, true);
    gate.videoelems.forEach(video => video.metadata());
    assert.ok(gate.videoelems.every(video => video.src && video.paused));
    assert.equal(get("position").value, 0);
    selectViewerTab(h, false);
    gate.currentsequence = undefined; // obsolete saved selection must not be revived
    selectViewerTab(h, true);
    assert.ok(gate.videoelems.every(video => !video.src));
  }
}

async function testInitialStatusGate() {
  const gateOffset = inlineScript.indexOf("var initialVideoListLoading = true;");
  const initializationOffset = inlineScript.search(/readconfig\(\);\s*initialize\(\);/);
  assert.ok(gateOffset >= 0 && initializationOffset > gateOffset,
    "the recording-list gate must be set before page initialization starts status polling");
  for (const scenario of [
    {name:"success", value:recordingPage()},
    {name:"timeout", error:new Error("Request timed out")},
    {name:"HTTP failure", error:new Error("scan timed out (HTTP 503)")},
    {name:"invalid JSON", value:"not JSON"},
    {name:"invalid schema", value:'{"videos":"invalid"}'},
    {name:"render failure", value:recordingPage(), renderFailure:true}
  ]) {
    const {gate, requests, timers, get} = recordingHarness();
    gate.showstatus();
    gate.showstatus();
    gate.updateuptimeonly();
    assert.equal(requests.length, 0, scenario.name + ": no status request during initial index load");
    assert.equal(timers.size, 0, "waiting must not start another polling chain");
    assert.match(get(".status_refresh").textContent, /Status not checked yet.*recording list/);
    assert.equal(get(".status_drives").textContent, "Camera drive: status update pending");
    gate.loadRecordings("latest");
    assert.equal(gate.loadRecordings("2026-09-06"), false, "overlapping scans must be refused");
    assert.deepEqual(requests.map((request) => request.url), ["/api/v1/videos?day=latest"]);
    if (scenario.renderFailure) gate.renderVideoList = () => { throw new Error("render failure"); };
    await requests[0].callback(scenario.value, undefined, scenario.error);
    assert.equal(gate.initialVideoListLoading, false, scenario.name + ": release the gate");
    assert.deepEqual(requests.map((request) => request.url), ["/api/v1/videos?day=latest", "/api/v1/status"]);
    assert.equal(timers.size, 1, scenario.name + ": resume exactly one polling chain");
    assert.equal(get(".status_refresh").textContent, "Updating status...");
    assert.equal(get(".noclips").textContent,
      scenario.name === "success" ? "No recordings" : "Recordings unavailable");
    assert.equal(get("recording-refresh").disabled, false);
    assert.equal(get("recording-day").disabled, false);
    gate.finishInitialVideoListLoad();
    assert.equal(requests.length, 2, "duplicate completion must not request status twice");
    assert.equal(timers.size, 1, "duplicate completion must not schedule another poll");
  }
}

async function testRecordingRefresh() {
  const {gate, requests, timers, get} = recordingHarness();
  const today = "RecentClips/2026-09-07/2026-09-07_09-00-00-front.mp4";
  const yesterday = "RecentClips/2026-09-06/2026-09-06_09-00-00-front.mp4";
  gate.loadRecordings("latest");
  await requests[0].callback(recordingPage("2026-09-07", [today]));
  assert.equal(gate.recordingLibrary.loaded, true);
  assert.equal(get("RecentClips").childElementCount, 1);
  const selected = gate.currentsequence;
  selected.play(); selected.seekTo(12345);
  gate.statusRequestInFlight = false;
  gate.loadRecordings();
  const refresh = requests.at(-1);
  await refresh.callback(recordingPage("2026-09-07", [today]));
  assert.equal(gate.currentsequence, selected, "unchanged selected media keeps playing without a reload");
  assert.equal(selected.isPlaying(), true);
  assert.equal(get("position").value, 12345);
  assert.equal(selected.segments.length, 1);
  assert.equal(get("RecentClips").childElementCount, 1, "refresh replaces, rather than duplicates, dropdowns");
  assert.equal(timers.size, 1, "refresh does not multiply status timers");
  const oldLibrary = gate.videos;
  const oldNode = get("RecentClips").lastChild;
  gate.statusRequestInFlight = false;
  gate.loadRecordings("2026-09-06");
  await requests.at(-1).callback(null, null, new Error("busy (HTTP 503)"));
  assert.equal(gate.videos, oldLibrary);
  assert.equal(get("RecentClips").lastChild, oldNode);
  assert.equal(gate.currentsequence, selected);
  assert.equal(get("recording-day").value, "latest");
  assert.match(get("viewerstatus").textContent, /previous library is still shown/);
  gate.statusRequestInFlight = false;
  const makeDropdown = gate.makeDropdownItem;
  gate.makeDropdownItem = () => { throw new Error("fixture dropdown construction failed"); };
  gate.loadRecordings("2026-09-06");
  await requests.at(-1).callback(recordingPage("2026-09-06", [yesterday]));
  gate.makeDropdownItem = makeDropdown;
  assert.equal(gate.videos, oldLibrary, "failed construction restores the prior library");
  assert.equal(get("RecentClips").lastChild, oldNode, "staged build failure does not replace working controls");
  assert.equal(gate.currentsequence, selected);
  gate.statusRequestInFlight = false;
  gate.loadRecordings("2026-09-06");
  assert.equal(requests.at(-1).url, "/api/v1/videos?day=2026-09-06");
  await requests.at(-1).callback(recordingPage("2026-09-06", [yesterday]));
  assert.equal(gate.currentsequence.sequencename, "2026-09-06");
  assert.equal(get("RecentClips").childElementCount, 1);
  assert.equal(gate.recordingLibrary.requestedDay, "2026-09-06");
  assert.match(get("recording-freshness").textContent, /camera filename time; timezone not supplied/);
  assert.equal(gate.loadRecordings("2026-02-30"), false);
  assert.throws(() => gate.parseRecordingPage(recordingPage("2026-09-07", [yesterday])), /not recognized/);
  gate.updateRecordingSnapshotEvidence({health:{snapshots:{available:true, scan_complete:true,
    last_completed:{name:"snap-000164", completed_at_utc:"2026-09-07T15:00:00+00:00"}}}});
  assert.match(get("recording-freshness").textContent, /snap-000164/);
  gate.updateRecordingSnapshotEvidence({health:{snapshots:{available:true, scan_complete:false,
    last_completed:{name:"snap-000165", completed_at_utc:"2026-09-07T15:00:00Z"}}}});
  assert.match(get("recording-freshness").textContent, /Last completed snapshot: unknown/);
  gate.statusRequestInFlight = false;
  gate.loadRecordings("2026-09-06");
  await requests.at(-1).callback(recordingPage("2026-09-06", []));
  assert.equal(get("RecentClips").childElementCount, 0, "successful empty response removes obsolete entries");
  assert.equal(gate.currentsequence, undefined);
}

function testLogTailFailures() {
  vm.runInContext(extractBetween("function starttailing", "function readyState"), context);
  context.isElementVisible = () => true;
  for (const [event, expected] of [["timeout", /timed out/], ["error", /Network error/],
    ["abort", /cancelled/], [undefined, /Network request failed/]]) {
    const timers = [];
    context.setTimeout = (callback, delay) => timers.push({callback, delay});
    resourceUpdates.length = 0;
    FakeXMLHttpRequest.nextResponse = {status:0, deferTerminal:true};
    const pre = {tailGeneration:1, textContent:"line\n"};
    context.starttailing({url:"archiveloop.log", pre, generation:1, status:"tail"});
    const request = FakeXMLHttpRequest.lastInstance;
    assert.equal(resourceUpdates.length, 0, "log tail DONE/status zero must wait for the terminal event");
    assert.equal(timers.length, 0);
    request.finish(event);
    assert.equal(resourceUpdates.length, 1);
    assert.match(resourceUpdates[0][1], expected);
    assert.equal(timers.length, 1, "one failure schedules one retry, not a retry storm");
    request.finish("error");
    assert.equal(resourceUpdates.length, 1);
    assert.equal(timers.length, 1);
  }
}

async function testRecordingWaitsForStatus() {
  const {gate, requests, timers} = recordingHarness();
  gate.statusRequestInFlight = true;
  gate.loadRecordings("latest");
  assert.equal(requests.length, 0, "an existing status request must finish before the scan starts");
  assert.equal(gate.loadRecordings("2026-09-06"), false);
  assert.equal(timers.size, 1);
  gate.statusRequestInFlight = false;
  const [id, timer] = timers.entries().next().value;
  timers.delete(id);
  timer.callback();
  assert.equal(requests[0].url, "/api/v1/videos?day=latest");
  await requests[0].callback(recordingPage());
  await requests[0].callback(null, null, new Error("late duplicate notification"));
  assert.equal(gate.recordingLibrary.loaded, true);
  assert.equal(requests.length, 2, "one scan completion resumes one status request");
  assert.equal(timers.size, 1);
}

async function run() {
  await testInitialStatusGate();
  await testRecordingRefresh();
  testLogTailFailures();
  await testRecordingWaitsForStatus();
  await testMediaSuspension();
  await testMediaRestoreRaces();
  await testMediaPlayPromiseOwnership();
  await testMediaRestoreRemapsAndUserSeek();
  await testViewerTabSuspension();
  await testViewerTabRefreshRaces();
  await testInitialLibraryAwayFromViewer();
  const normalCachebusting = context.cachebustingurl;
  context.cachebustingurl = url => url + "&_=unexpected";
  for (const day of ["latest", "2026-09-07"]) {
    FakeXMLHttpRequest.nextResponse = {status:200, responseText:"{}"};
    context.readfile({url:"/api/v1/videos?day=" + day});
    const sent = FakeXMLHttpRequest.lastInstance.url;
    assert.equal(sent, "/api/v1/videos?day=" + day);
    assert.deepEqual(Array.from(new URL(sent, "http://example.test").searchParams.keys()), ["day"],
      "the actual viewer XHR must preserve the backend's day-only query contract");
  }
  context.cachebustingurl = normalCachebusting;
  for (const [event, message] of [
    ["timeout", "Request timed out"],
    ["error", "Network error"],
    ["abort", "Request cancelled"],
    [undefined, "Network request failed"]
  ]) {
    for (const partial of ["", '{"videos":[']) {
      FakeXMLHttpRequest.nextResponse = {
        status: 0, statusText: "", responseText: partial, deferTerminal: true
      };
      const callbacks = [];
      resourceUpdates.length = 0;
      context.readfile({url: "/api/v1/videos",
        callback: (...args) => callbacks.push(args)});
      const readRequest = FakeXMLHttpRequest.lastInstance;
      assert.equal(readRequest.timeout, 30000);
      assert.equal(callbacks.length, 0, "DONE/status zero must wait for the failure event");
      assert.equal(resourceUpdates.length, 0);
      readRequest.finish(event);
      assert.equal(callbacks.length, 1);
      assert.equal(callbacks[0][0], null);
      assert.equal(callbacks[0][2].message, message);
      assert.equal(resourceUpdates.length, 1);
      // Late/duplicate notifications must not invoke the callback or UI twice.
      readRequest.onreadystatechange();
      readRequest.finish("error");
      assert.equal(callbacks.length, 1);
      assert.equal(resourceUpdates.length, 1);

      let settlements = 0;
      const resultPromise = context.apiRequest("/api/v1/status").then(
        () => { settlements++; throw new Error("unexpected success"); },
        (error) => { settlements++; return error; });
      const apiRequest = FakeXMLHttpRequest.lastInstance;
      await Promise.resolve();
      assert.equal(settlements, 0, "API DONE/status zero must wait for the failure event");
      apiRequest.finish(event);
      const error = await resultPromise;
      assert.equal(error.message, message);
      assert.equal(error.status, 0);
      apiRequest.onreadystatechange();
      apiRequest.finish("error");
      await Promise.resolve();
      assert.equal(settlements, 1);
    }
  }

  for (const status of [200, 404]) {
    FakeXMLHttpRequest.nextResponse = {
      status, statusText: status === 200 ? "OK" : "Not Found", responseText: "body"
    };
    const callbacks = [];
    context.readfile({url: "/api/v1/videos",
      callback: (...args) => callbacks.push(args)});
    FakeXMLHttpRequest.lastInstance.finish("error");
    assert.equal(callbacks.length, 1);
    if (status === 200) {
      assert.equal(callbacks[0][0], "body");
      assert.equal(callbacks[0][2], null);
    } else {
      assert.equal(callbacks[0][2].message, "HTTP 404 Not Found");
    }
  }

  for (const [url, responseText, expected] of [
    ["/api/v1/videos", '{"ok":false,"error":"Recording list scan timed out"}',
      "Recording list scan timed out (HTTP 503)"],
    ["/api/v1/videos", "<html>upstream unavailable</html>", "HTTP 503 Service Unavailable"],
    ["/api/v1/videos", "not JSON", "HTTP 503 Service Unavailable"],
    ["/api/v1/videos", '{"ok":false,"error":123}', "HTTP 503 Service Unavailable"],
    ["/api/v1/videos", '{"ok":true,"error":"not a failure"}', "HTTP 503 Service Unavailable"],
    ["/api/v1/videos", '{"ok":false,"error":"  "}', "HTTP 503 Service Unavailable"],
    ["/api/v1/videos", JSON.stringify({ok:false, error:"x".repeat(600)}),
      "x".repeat(500) + " (HTTP 503)"],
    ["/api/v1/videos", JSON.stringify({ok:false, error:"bad\npath\u0000"}),
      "bad path (HTTP 503)"],
    ["/api/v1/videos", JSON.stringify({ok:false, error:"x".repeat(17000)}),
      "HTTP 503 Service Unavailable"],
    ["/TeslaCam/file.mp4", '{"ok":false,"error":"not an API response"}',
      "HTTP 503 Service Unavailable"]
  ]) {
    FakeXMLHttpRequest.nextResponse = {status:503, statusText:"Service Unavailable", responseText};
    const callbacks = [];
    context.readfile({url, callback: (...args) => callbacks.push(args)});
    assert.equal(callbacks.length, 1);
    assert.equal(callbacks[0][2].message, expected);
    assert.equal(callbacks[0][2].status, 503);
  }

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
  await assert.rejects(context.callcgi("/api/v1/actions/sync"), /Network error/);

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
