import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const htmlRoot = fileURLToPath(new URL('../teslausb-www/html/', import.meta.url));
const source = fs.readFileSync(path.join(htmlRoot, 'modern/trash.js'), 'utf8');
const { trashStorageView } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const MiB = 1024 ** 2, GiB = 1024 ** 3;
const entry = (id, bytes) => ({ id, bytes, event: `SentryClips/2026-09-08_12-0${id}-00`, category: 'SentryClips', event_time: `2026-09-08_12-0${id}-00`, deleted_at: '2026-09-08T12:00:00Z', expires_at: '2026-10-08T12:00:00Z', files: [] });
const fixture = () => ({ ok: true, items: [entry('1', GiB), entry('2', 512 * MiB)], restored: [entry('3', 2 * GiB)], retained_bytes: 3.5 * GiB, free_bytes: 20 * GiB, reserve_bytes: GiB, clock: { trusted: true } });

const populated = trashStorageView(fixture());
assert.deepEqual(populated.trash, { count: 2, bytes: 1.5 * GiB });
assert.deepEqual(populated.restored, { count: 1, bytes: 2 * GiB });
assert.equal(populated.retainedBytes, 3.5 * GiB);
assert.equal(populated.retainedCount, 3);
assert.equal(populated.aboveReserveBytes, 19 * GiB);
assert.equal(populated.incomplete, false);
assert.equal(populated.inconsistent, false);

const zero = trashStorageView({ items: [], restored: [], retained_bytes: 0, free_bytes: 0, reserve_bytes: 0 });
assert.deepEqual(zero.trash, { count: 0, bytes: 0 });
assert.equal(zero.retainedBytes, 0);
assert.equal(zero.aboveReserveBytes, 0);
assert.equal(zero.incomplete, false, 'Explicit zero measurements remain valid');
for (const value of [undefined, null, {}, { items: null, restored: {} }]) {
  const missing = trashStorageView(value);
  assert.deepEqual(missing.trash, { count: null, bytes: null });
  assert.deepEqual(missing.restored, { count: null, bytes: null });
  assert.equal(missing.retainedBytes, null);
  assert.equal(missing.freeBytes, null);
  assert.equal(missing.reserveBytes, null);
  assert.equal(missing.aboveReserveBytes, null);
  assert.equal(missing.incomplete, true, 'Missing measurements must not become zero');
}
for (const bad of [null, undefined, '', '1024', false, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
  const malformed = trashStorageView({ ...fixture(), items: [entry('1', bad)], retained_bytes: bad, free_bytes: bad, reserve_bytes: bad });
  assert.deepEqual(malformed.trash, { count: 1, bytes: null });
  assert.equal(malformed.retainedBytes, null);
  assert.equal(malformed.freeBytes, null);
  assert.equal(malformed.reserveBytes, null);
  assert.equal(malformed.aboveReserveBytes, null);
}
const overflow = trashStorageView({ items: [entry('1', Number.MAX_SAFE_INTEGER), entry('2', 1)], restored: [] });
assert.equal(overflow.trash.bytes, null, 'Unsafe aggregate precision is unavailable');
assert.equal(trashStorageView({ ...fixture(), items: [null] }).trash.count, null);
assert.equal(trashStorageView({ ...fixture(), items: [entry('1', 1), entry('1', 1)] }).trash.bytes, null, 'Duplicate copies are not counted twice');
assert.equal(trashStorageView({ ...fixture(), retained_bytes: 0 }).inconsistent, true);
const overlapping = trashStorageView({ items: [entry('1', 1)], restored: [entry('1', 1)], retained_bytes: 2 });
assert.equal(overlapping.inconsistent, true);
assert.equal(overlapping.retainedCount, null, 'A copy listed in both states has no reliable combined count');
const reserveShortfall = trashStorageView({ ...fixture(), free_bytes: 64 * MiB, reserve_bytes: 256 * MiB });
assert.equal(reserveShortfall.aboveReserveBytes, 0);
assert.equal(reserveShortfall.belowReserve, true);
const restoredOnly = trashStorageView({ ...fixture(), items: [], retained_bytes: 2 * GiB });
assert.deepEqual(restoredOnly.trash, { count: 0, bytes: 0 });
assert.deepEqual(restoredOnly.restored, { count: 1, bytes: 2 * GiB });
assert.equal(restoredOnly.retainedBytes, 2 * GiB, 'Empty Trash can still retain restored copies');
console.log('Trash storage contract passed: zero, unavailable/malformed bytes, overflow, inconsistent totals, reserve shortfall, and restored copies.');

// Optional browser coverage: NODE_PATH must include Playwright. All API responses
// and mutations below belong to a temporary localhost fixture, never to a Pi.
if (process.argv.includes('--browser')) {
  const { chromium } = createRequire(import.meta.url)('playwright');
  let state = fixture(), browser;
  const mutations = [], errors = [];
  const harness = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Trash storage fixture</title><link rel="stylesheet" href="/modern/trash.css"><style>:root{--bg:#10141b;--surface:#191f2a;--soft:#202938;--line:#303b4a;--text:#e7edf5;--muted:#a5b2c5;--accent:#54d0b2;--danger:#ff7c88}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px Arial,sans-serif;padding:24px}main{margin:auto} @media(max-width:580px){body{padding:16px}}</style><main id="mount"></main><script type="module">import{mountTrash}from'/modern/trash.js';window.trash=mountTrash(document.querySelector('#mount'));</script></html>`;
  const server = http.createServer(async (request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    if (pathname === '/') { response.setHeader('Content-Type', 'text/html'); response.end(harness); return; }
    if (pathname.startsWith('/api/v1/')) {
      response.setHeader('Content-Type', 'application/json');
      if (request.method === 'GET' && pathname === '/api/v1/trash') { response.end(JSON.stringify(state)); return; }
      if (request.method === 'POST' && ['/api/v1/trash/restore', '/api/v1/trash/delete'].includes(pathname)) {
        let body = ''; for await (const chunk of request) body += chunk;
        const { ids } = JSON.parse(body);
        mutations.push({ path: pathname, ids, csrf: request.headers['x-teslausb-request'] });
        const chosen = state.items.filter(item => ids.includes(item.id));
        state.items = state.items.filter(item => !ids.includes(item.id));
        if (pathname.endsWith('/restore')) state.restored.push(...chosen);
        else { const removed = chosen.reduce((sum, item) => sum + item.bytes, 0); state.retained_bytes -= removed; state.free_bytes += removed; }
        response.end(JSON.stringify(state)); return;
      }
      response.writeHead(404); response.end(JSON.stringify({ ok: false, error: 'Unknown fixture endpoint' })); return;
    }
    if (['/modern/trash.js', '/modern/trash.css'].includes(pathname)) {
      response.setHeader('Content-Type', pathname.endsWith('.js') ? 'text/javascript' : 'text/css');
      fs.createReadStream(path.join(htmlRoot, pathname.slice(1))).pipe(response); return;
    }
    response.writeHead(404); response.end();
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome', headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 1200 } });
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.locator('.trash-summary').filter({ hasText: '2 recordings in Trash' }).waitFor();
    const amount = key => page.locator(`[data-storage="${key}"] dd`).textContent();
    assert.equal(await amount('trash'), '1.5 GiB');
    assert.equal(await amount('restored'), '2 GiB');
    assert.equal(await amount('retained'), '3.5 GiB');
    assert.equal(await amount('free'), '20 GiB');
    assert.equal(await amount('reserve'), '1 GiB');
    assert.equal(await amount('above-reserve'), '19 GiB');
    assert.match(await page.locator('.trash-policy').textContent(), /Original snapshots, car recordings, and archive copies are unchanged/);
    assert.match(await page.locator('.trash-storage-note').textContent(), /logical file sizes/);
    await page.screenshot({ path: path.join(os.tmpdir(), 'teslausb-modern-trash-storage-desktop.png'), fullPage: true });
    await page.getByRole('button', { name: 'Restore', exact: true }).first().click();
    await page.locator('.trash-message').filter({ hasText: '1 recording restored' }).waitFor();
    assert.equal(await amount('trash'), '512 MiB');
    assert.equal(await amount('restored'), '3 GiB');
    assert.equal(await amount('retained'), '3.5 GiB', 'Restoring reuses the copy without freeing retained storage');
    assert.equal(await amount('free'), '20 GiB');
    assert.deepEqual(mutations[0], { path: '/api/v1/trash/restore', ids: ['1'], csrf: '1' });
    await page.getByRole('button', { name: 'Empty Trash', exact: true }).click();
    await page.locator('dialog').getByRole('button', { name: 'Delete permanently', exact: true }).click();
    await page.locator('.trash-message').filter({ hasText: '1 preserved recording permanently deleted' }).waitFor();
    assert.deepEqual(mutations[1], { path: '/api/v1/trash/delete', ids: ['2'], csrf: '1' });
    assert.equal(await amount('trash'), '0 B');
    assert.equal(await amount('restored'), '3 GiB');
    assert.equal(await amount('retained'), '3 GiB', 'Empty Trash does not delete restored copies');
    assert.equal(await page.getByRole('button', { name: 'Empty Trash', exact: true }).isDisabled(), true);
    assert.match(await page.locator('.trash-empty').textContent(), /Restored copies still use storage/);
    assert.match(await page.locator('.trash-restored-help').textContent(), /Saved or Sentry in Recordings.*Trash again.*permanently/);
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true, 'Storage fits 390px without horizontal scrolling');
    await page.screenshot({ path: path.join(os.tmpdir(), 'teslausb-modern-trash-storage-mobile.png'), fullPage: true });
    state = {};
    await page.evaluate(() => window.trash.refresh());
    for (const key of ['trash', 'restored', 'retained', 'free', 'reserve', 'above-reserve']) assert.equal(await amount(key), 'Not reported');
    assert.match(await page.locator('.trash-summary').textContent(), /unavailable/);
    assert.doesNotMatch(await page.locator('.trash-empty').textContent(), /Trash is empty/);
    assert.equal(await page.locator('.trash-storage-warning').isVisible(), true);
    state = { ok: true, items: [], restored: [], retained_bytes: 0, free_bytes: 0, reserve_bytes: 0 };
    await page.evaluate(() => window.trash.refresh());
    for (const key of ['trash', 'restored', 'retained', 'free', 'reserve', 'above-reserve']) assert.equal(await amount(key), '0 B');
    assert.equal(await page.locator('.trash-storage-warning').isVisible(), false);
    state = { ...fixture(), retained_bytes: GiB, free_bytes: 64 * MiB, reserve_bytes: 256 * MiB };
    await page.evaluate(() => window.trash.refresh());
    assert.equal(await amount('retained'), '1 GiB', 'The API total is kept rather than silently replaced with a computed total');
    assert.match(await page.locator('.trash-storage-warning').textContent(), /inconsistent/);
    assert.equal(await amount('above-reserve'), '0 B');
    assert.match(await page.locator('[data-storage="above-reserve"]').textContent(), /below the reserve/);
    state = { ...fixture(), items: [entry('1', null)] };
    await page.evaluate(() => window.trash.refresh());
    assert.equal(await amount('trash'), 'Not reported');
    assert.match(await page.locator('.trash-item-head').textContent(), /Not reported/);
    assert.deepEqual(errors, []);
    assert.equal(mutations.length, 2, 'Only the two explicit fixture operations mutate state');
    await page.evaluate(() => window.trash.destroy());
    console.log('Trash storage browser passed: restore, empty retains restored copies, guarded fixture deletion, malformed/zero measurements, and 390px layout.');
  } finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
  }
}
