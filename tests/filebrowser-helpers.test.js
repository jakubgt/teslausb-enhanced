"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {
  FileBrowser,
  fileBrowserCgiUrl,
  fileBrowserDeleteConfirmation,
  fileBrowserEncodePath,
  fileBrowserIsSameOrDescendantPath
} = require("../teslausb-www/html/filebrowser.js");

const fileBrowserSource = fs.readFileSync(
  path.join(__dirname, "..", "teslausb-www", "html", "filebrowser.js"),
  "utf8");
assert.doesNotMatch(fileBrowserSource, /cgi-bin\//);
assert.match(
  fileBrowserSource,
  /fileBrowserCgiUrl\("upload\.sh"[\s\S]*?setRequestHeader\("X-TeslaUSB-Request", "1"\)/);

assert.equal(
  fileBrowserCgiUrl("mv.sh", "fs/Music", "A & B", "100%", "#hash"),
  "/api/v1/files/move?fs%2FMusic&A%20%26%20B&100%25&%23hash");
assert.equal(
  fileBrowserCgiUrl("ls.sh", "fs/Music", "."),
  "/api/v1/files/list?fs%2FMusic&.");
assert.throws(() => fileBrowserCgiUrl("unknown.sh"), /Unsupported file API operation/);

assert.equal(
  fileBrowserEncodePath("fs/Music/A & B/#1%.mp3"),
  "fs/Music/A%20%26%20B/%231%25.mp3");

assert.equal(fileBrowserIsSameOrDescendantPath("Foo", "Foo"), true);
assert.equal(fileBrowserIsSameOrDescendantPath("Foo", "Foo/Bar"), true);
assert.equal(fileBrowserIsSameOrDescendantPath("Foo/", "Foo/Bar/"), true);
assert.equal(fileBrowserIsSameOrDescendantPath("Foo", "Foobar"), false);
assert.equal(fileBrowserIsSameOrDescendantPath("Foo/Bar", "Foo/Barn"), false);
assert.equal(fileBrowserIsSameOrDescendantPath("Foo/Bar", "Foo/Baz"), false);

const singleDelete = fileBrowserDeleteConfirmation(["clip.mp4"]);
assert.match(singleDelete, /Delete this item\?/);
assert.match(singleDelete, /clip\.mp4/);
assert.match(singleDelete, /cannot be undone/i);

const multiDelete = fileBrowserDeleteConfirmation([
  "one", "two", "three", "four", "five", "six\nwith newline"
]);
assert.match(multiDelete, /Delete these 6 items\?/);
assert.match(multiDelete, /and 1 more/);
assert.doesNotMatch(multiDelete, /six\nwith newline/);

class FakeXMLHttpRequest {
  static DONE = 4;
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
    Object.assign(this, FakeXMLHttpRequest.nextResponse, {readyState: FakeXMLHttpRequest.DONE});
    this.onreadystatechange();
    if (FakeXMLHttpRequest.nextResponse.fireError) {
      this.onerror();
    }
  }
}

global.XMLHttpRequest = FakeXMLHttpRequest;
const browser = Object.create(FileBrowser.prototype);

function readWithResponse(response) {
  FakeXMLHttpRequest.nextResponse = response;
  const calls = [];
  browser.readfile({
    url: "/api/v1/files/list?fs%2FMusic&.",
    callbackarg: "kept",
    callback: (...args) => calls.push(args)
  });
  return calls;
}

let calls = readWithResponse({status: 200, statusText: "OK", responseText: "body"});
assert.equal(calls.length, 1);
assert.deepEqual(calls[0], ["body", "kept", null]);
assert.equal(FakeXMLHttpRequest.lastInstance.method, "GET");

calls = readWithResponse({status: 400, statusText: "Bad Request", responseText: "bad"});
assert.equal(calls.length, 1);
assert.equal(calls[0][0], "bad");
assert.equal(calls[0][1], "kept");
assert.equal(calls[0][2].status, 400);

calls = readWithResponse({
  status: 0,
  statusText: "",
  responseText: "",
  fireError: true
});
assert.equal(calls.length, 1);
assert.equal(calls[0][2].status, 0);
assert.equal(FakeXMLHttpRequest.lastInstance.timeout, 30000);

let mutationSucceeded = false;
let mutationError = null;
browser.showOperationStatus = () => {};
browser.showOperationError = (action, error, detail) => {
  mutationError = {action, error, detail};
};
FakeXMLHttpRequest.nextResponse = {
  status: 200,
  statusText: "OK",
  responseText: '{"ok":true,"message":"moved"}'
};
browser.runMutation("/api/v1/files/move?fs%2FMusic&A&B", "move the item", () => {
  mutationSucceeded = true;
});
assert.equal(mutationSucceeded, true);
assert.equal(mutationError, null);
assert.equal(FakeXMLHttpRequest.lastInstance.method, "POST");
assert.equal(FakeXMLHttpRequest.lastInstance.headers["X-TeslaUSB-Request"], "1");

FakeXMLHttpRequest.nextResponse = {
  status: 403,
  statusText: "Forbidden",
  responseText: '{"ok":false,"error":"Request blocked"}'
};
browser.runMutation("/api/v1/files/delete?fs%2FMusic&A", "delete the item");
assert.equal(mutationError.action, "delete the item");
assert.equal(mutationError.error.status, 403);
assert.equal(mutationError.detail, "Request blocked");

console.log("filebrowser helper tests passed");
