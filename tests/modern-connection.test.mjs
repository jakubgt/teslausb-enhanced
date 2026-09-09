import assert from 'node:assert/strict';
import test from 'node:test';
import {mountConnectionBanner} from '../teslausb-www/html/modern/connection.mjs';

// A deliberately small DOM/event fixture: the production module runs unchanged,
// while every request and browser-network event is supplied explicitly. No fetch,
// network server, browser installation, or device connection is needed.
class FixtureElement extends EventTarget {
  constructor(tag, document) {
    super(); this.tagName = tag; this.ownerDocument = document; this.children = [];
    this.attributes = new Map(); this.dataset = {}; this.className = ''; this.textContent = '';
    this.hidden = false; this.disabled = false;
    this.classList = {
      add: name => { this.className = [...new Set([...this.className.split(' ').filter(Boolean), name])].join(' '); },
      remove: name => { this.className = this.className.split(' ').filter(value => value !== name).join(' '); },
    };
  }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children = nodes; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  removeAttribute(name) { this.attributes.delete(name); }
}
class FixtureWindow extends EventTarget {
  constructor(online) { super(); this.navigator = {onLine: online}; this.listeners = new Map(); }
  addEventListener(name, callback, options) {
    const listeners = this.listeners.get(name) || new Set(); listeners.add(callback); this.listeners.set(name, listeners);
    super.addEventListener(name, callback, options);
  }
  removeEventListener(name, callback, options) {
    this.listeners.get(name)?.delete(callback); super.removeEventListener(name, callback, options);
  }
}
function fixture(options = {}, online = true) {
  const view = new FixtureWindow(online);
  const document = {defaultView: view, createElement: tag => new FixtureElement(tag, document)};
  const container = new FixtureElement('section', document);
  const api = mountConnectionBanner(container, options);
  const descendants = node => [node, ...node.children.flatMap(descendants)];
  const find = name => descendants(container).find(node => node.className.split(' ').includes(name));
  return {view, container, api, find, state: () => container.dataset.state,
    title: () => find('connection-title').textContent,
    detail: () => find('connection-detail').textContent,
    click: () => find('connection-retry').dispatchEvent(new Event('click'))};
}
const flush = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return {promise, resolve, reject}; }

test('initial state is Connecting without inventing a last server response', () => {
  const f = fixture();
  assert.equal(f.state(), 'connecting'); assert.equal(f.title(), 'Connecting');
  assert.equal(f.find('connection-contact').textContent, 'No server response yet.');
  assert.equal(f.find('connection-retry').hidden, false);
  assert.equal(f.find('connection-live').getAttribute('role'), 'status');
  assert.equal(f.find('connection-retry').getAttribute('aria-label'), 'Retry connection');
  f.api.destroy();
});

test('server response records contact and Connected; starting another request does not flicker', () => {
  const f = fixture();
  f.api.receivedResponse(f.api.beginRequest());
  assert.equal(f.state(), 'connected'); assert.equal(f.find('connection-retry').hidden, true);
  assert.ok(Number.isFinite(Date.parse(f.find('connection-contact').getAttribute('data-contact-at'))));
  assert.match(f.find('connection-contact').textContent, /Last successful contact:/);
  f.api.beginRequest(); assert.equal(f.state(), 'connected');
  f.api.destroy();
});

test('a new transport failure loses connection while preserving last successful contact', () => {
  const f = fixture(); f.api.receivedResponse(f.api.beginRequest());
  const contact = f.find('connection-contact').textContent;
  f.api.requestFailed(f.api.beginRequest());
  assert.equal(f.state(), 'lost'); assert.equal(f.title(), 'Connection lost');
  assert.equal(f.find('connection-contact').textContent, contact);
  assert.equal(f.find('connection-retry').hidden, false); f.api.destroy();
});

test('late failure from an earlier concurrent request cannot replace newer server contact', () => {
  const f = fixture(); const first = f.api.beginRequest(); const second = f.api.beginRequest();
  f.api.receivedResponse(second); f.api.requestFailed(first);
  assert.equal(f.state(), 'connected'); f.api.destroy();
});

test('even a later-started concurrent request timeout is stale after another request responds', () => {
  const f = fixture(); const first = f.api.beginRequest(); const second = f.api.beginRequest();
  f.api.receivedResponse(first); f.api.requestFailed(second);
  assert.equal(f.state(), 'connected');
  f.api.requestFailed(f.api.beginRequest()); assert.equal(f.state(), 'lost'); f.api.destroy();
});

test('any fresh response proves contact even if its request started before another failure', () => {
  const f = fixture(); const first = f.api.beginRequest(); const second = f.api.beginRequest();
  f.api.requestFailed(second); assert.equal(f.state(), 'lost');
  f.api.receivedResponse(first); assert.equal(f.state(), 'connected'); f.api.destroy();
});

test('tokens are scoped to their mount, immutable, and consumed once', () => {
  const f = fixture(); const other = fixture(); const token = f.api.beginRequest();
  assert.ok(Object.isFrozen(token));
  other.api.receivedResponse(token); assert.equal(other.state(), 'connecting');
  f.api.requestFailed({sequence: 9999}); assert.equal(f.state(), 'connecting');
  f.api.receivedResponse(token); f.api.requestFailed(token); assert.equal(f.state(), 'connected');
  f.api.receivedResponse(null); f.api.requestFailed(undefined); assert.equal(f.state(), 'connected');
  f.api.destroy(); other.api.destroy();
});

test('browser offline reports loss, while online never claims server contact or retries itself', () => {
  let retries = 0; const f = fixture({retry: async () => { retries += 1; }});
  f.view.dispatchEvent(new Event('online')); assert.equal(f.state(), 'connecting');
  f.api.receivedResponse(f.api.beginRequest());
  f.view.dispatchEvent(new Event('offline')); assert.equal(f.state(), 'lost'); assert.match(f.detail(), /no network/);
  f.view.dispatchEvent(new Event('online')); assert.equal(f.state(), 'lost'); assert.match(f.detail(), /Retry to check TeslaUSB/);
  assert.equal(retries, 0); f.api.destroy();
});

test('an initially offline browser remains lost until an actual response', () => {
  const f = fixture({}, false); assert.equal(f.state(), 'lost');
  f.view.dispatchEvent(new Event('online')); assert.equal(f.state(), 'lost');
  f.api.receivedResponse(f.api.beginRequest()); assert.equal(f.state(), 'connected'); f.api.destroy();
});

test('Retry is single-flight and remains Connecting until supplied HTTP evidence', async () => {
  const work = deferred(); let retries = 0;
  const f = fixture({retry: async () => { retries += 1; await work.promise; }});
  f.api.requestFailed(f.api.beginRequest()); f.click(); f.click();
  assert.equal(retries, 1); assert.equal(f.state(), 'connecting');
  assert.equal(f.find('connection-retry').disabled, true);
  assert.equal(f.find('connection-retry').getAttribute('aria-busy'), 'true');
  f.api.receivedResponse(f.api.beginRequest()); work.resolve(); await flush();
  assert.equal(f.state(), 'connected'); assert.equal(f.find('connection-retry').disabled, false);
  f.api.destroy();
});

test('resolving a Retry promise without an HTTP response does not invent success', async () => {
  const f = fixture({retry: async () => {}});
  f.api.requestFailed(f.api.beginRequest()); f.click(); await flush();
  assert.equal(f.state(), 'lost'); assert.match(f.detail(), /No new server response/); f.api.destroy();
});

test('HTTP or application error after a response still means Connected', async () => {
  let f;
  f = fixture({retry: async () => {
    f.api.receivedResponse(f.api.beginRequest());
    const error = new Error('HTTP 503 application unavailable'); error.status = 503; throw error;
  }});
  f.api.requestFailed(f.api.beginRequest()); f.click(); await flush();
  assert.equal(f.state(), 'connected'); assert.equal(f.title(), 'Connected'); f.api.destroy();
});

test('Retry rejection without transport evidence does not turn a known contact into loss', async () => {
  const f = fixture({retry: async () => { throw new Error('User aborted or local validation failed'); }});
  f.api.receivedResponse(f.api.beginRequest()); f.click(); await flush();
  assert.equal(f.state(), 'connected'); f.api.destroy();
});

test('power-action pause persists through background responses and online events', () => {
  let paused = true; const f = fixture({isPaused: () => paused});
  assert.equal(f.state(), 'paused'); assert.match(f.title(), /paused/); assert.match(f.detail(), /power action/);
  f.api.receivedResponse(f.api.beginRequest()); assert.equal(f.state(), 'paused');
  f.view.dispatchEvent(new Event('offline')); f.view.dispatchEvent(new Event('online'));
  assert.equal(f.state(), 'paused'); assert.match(f.detail(), /power action/);
  f.api.receivedResponse(f.api.beginRequest()); paused = false; f.api.setPaused();
  assert.equal(f.state(), 'connected'); f.api.destroy();
});

test('explicit Retry can refresh paused Device state without repeating a power mutation', async () => {
  let paused = true; let reads = 0; let f;
  f = fixture({isPaused: () => paused, retry: async () => {
    reads += 1; f.api.receivedResponse(f.api.beginRequest()); paused = false;
  }});
  f.click(); await flush();
  assert.equal(reads, 1); assert.equal(f.state(), 'connected'); f.api.destroy();
});

test('destroy removes listeners and ignores late retry completion and request evidence', async () => {
  const work = deferred(); const f = fixture({retry: () => work.promise});
  const token = f.api.beginRequest(); f.click(); f.api.destroy();
  assert.equal(f.view.listeners.get('offline').size, 0); assert.equal(f.view.listeners.get('online').size, 0);
  work.resolve(); await flush(); f.api.receivedResponse(token); f.api.requestFailed(token); f.api.setPaused();
  f.view.dispatchEvent(new Event('offline')); f.view.dispatchEvent(new Event('online'));
  assert.equal(f.container.children.length, 0); assert.equal(f.api.beginRequest(), null);
  assert.equal(f.container.getAttribute('role'), null); f.api.destroy();
});
