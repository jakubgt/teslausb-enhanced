'use strict';
// Optional browser integration check: NODE_PATH must include Playwright.
// All device endpoints are intercepted; this never connects to a Pi.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {chromium} = require('playwright');

const htmlRoot = path.resolve(__dirname, '../teslausb-www/html');
const harness = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>:root{--bg:#10141b;--surface:#191f2a;--soft:#202938;--line:#303b4a;--text:#e7edf5;--muted:#95a5bb;--accent:#54d0b2;--danger:#ff7c88;--success:#54d0b2}body{margin:0;background:var(--bg);font:14px Arial,sans-serif;padding:30px}*{box-sizing:border-box}</style><link rel="stylesheet" href="/modern/device.css"></head><body><div id="mount"></div><script type="module">import{mountDevice}from'/modern/device.js';import{mountFiles}from'/modern/files.js';const api=async(path,options)=>{const response=await fetch(path,options);if(!response.ok)throw new Error('HTTP '+response.status);return response.json()};window.openDevice=()=>{window.active?.destroy();window.active=mountDevice(document.querySelector('#mount'),{api})};window.openFiles=()=>{window.active?.destroy();window.active=mountFiles(document.querySelector('#mount'),{api,config:{has_music:'yes',has_lightshow:'yes'}})};window.openDevice();</script></body></html>`;

async function run() {
  const server = http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    if (pathname === '/') { response.setHeader('Content-Type', 'text/html'); response.end(harness); return; }
    const filename = path.resolve(htmlRoot, '.' + pathname);
    if (!filename.startsWith(htmlRoot + path.sep) || !fs.existsSync(filename) || !fs.statSync(filename).isFile()) { response.writeHead(404); response.end(); return; }
    response.setHeader('Content-Type', filename.endsWith('.js') ? 'text/javascript' : filename.endsWith('.css') ? 'text/css' : 'image/svg+xml'); fs.createReadStream(filename).pipe(response);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome', headless: true});
    const page = await browser.newPage({viewport: {width: 1440, height: 1080}, acceptDownloads: true});
    const errors = [], mutations = [];
    let failStatus = false;
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/api/v1/**', async route => {
      const request = route.request(), pathname = new URL(request.url()).pathname;
      if (pathname === '/api/v1/status') {
        if (failStatus) return route.fulfill({status: 503, body: 'Offline'});
        return route.fulfill({json: {uptime: '90061', total_space: 100000000000, free_space: 20000000000, cpu_temp: '53000', fan_speed: '1200', camera_drive_state: 'connected', drives_active: 'yes', wifi_ssid: 'Garage', wifi_ip: '192.0.2.42', throttled: '0x10000', archive_status: {schema_version: 1, last_result: 'running', pending_files: 3, pending_bytes: 3000, transferred_files: 2, transferred_bytes: 2000}}});
      }
      if (pathname === '/api/v1/maintenance') return route.fulfill({json: {schema_version: 1, ssh: {service_state: 'active', enabled_state: 'enabled'}, health: {schema_version: 1, snapshots: {available: true, scan_complete: true, completed_count: 8, last_completed: {completed_at_utc: '2026-09-08T15:00:00Z'}}, storage: {}, read_only: {root: true, boot: true}}, logs: {diagnostics: {available: true, size_bytes: 24}, archiveloop: {available: true, truncated: true, size_bytes: 10000000}}}});
      if (pathname.startsWith('/api/v1/maintenance/logs/')) return route.fulfill({status: 200, contentType: 'text/plain;charset=utf-8', headers: {'X-TeslaUSB-Truncated': pathname.endsWith('archiveloop') ? 'true' : 'false', 'X-TeslaUSB-Original-Size': pathname.endsWith('archiveloop') ? '10000000' : '24'}, body: 'first line\nERROR useful\nlast line\n'});
      if (pathname.startsWith('/api/v1/actions/')) { mutations.push({path: pathname, method: request.method(), csrf: request.headers()['x-teslausb-request']}); return route.fulfill({json: {ok: true}}); }
      if (pathname === '/api/v1/speed-test') return route.fulfill({body: Buffer.alloc(1024), contentType: 'application/octet-stream'});
      if (pathname === '/api/v1/files/list') return route.fulfill({contentType: 'text/plain', body: 'd:Albums\nf:Song & title.mp3:12345\nf:LockChime.wav:400\ns:100000:200000\n'});
      if (pathname === '/api/v1/files/mkdir') { mutations.push({path: pathname, method: request.method(), csrf: request.headers()['x-teslausb-request']}); return route.fulfill({json: {ok: true}}); }
      return route.fulfill({status: 404, body: 'Not in fixture'});
    });
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.getByText(/Status refreshed/).waitFor();
    assert.equal(await page.getByText('Undervoltage occurred since restart', {exact: true}).count(), 1);
    await page.getByRole('tab', {name: 'Archive', exact: true}).click();
    assert.equal(await page.getByText('Transferring 2 of 5 files').count(), 1);
    assert.equal(await page.getByRole('button', {name: 'Sync now'}).isDisabled(), true);
    await page.getByRole('tab', {name: 'Diagnostics & logs'}).click();
    await page.getByText(/Complete saved file captured/).waitFor();
    await page.getByRole('searchbox').fill('ERROR');
    assert.equal(await page.locator('[data-device="log-text"]').textContent(), 'ERROR useful');
    const downloadEvent = page.waitForEvent('download'); await page.getByRole('button', {name: 'Download capture', exact: true}).click();
    const download = await downloadEvent;
    assert.equal(fs.readFileSync(await download.path(), 'utf8'), 'first line\nERROR useful\nlast line\n', 'Downloads must contain the full capture despite search filtering');
    await page.getByRole('button', {name: 'View full capture'}).click();
    assert.match(await page.locator('dialog pre').textContent(), /first line/);
    await page.getByRole('button', {name: 'Close', exact: true}).click();
    await page.locator('[data-log="archiveloop"]').click();
    await page.getByText(/Only the latest 8 MiB/).waitFor();
    await page.getByRole('tab', {name: 'Tools', exact: true}).click();
    await page.evaluate(() => { window.pauses = 0; window.addEventListener('teslausb:pause-media', () => window.pauses++); });
    await page.getByRole('button', {name: 'Run 15-second test'}).click();
    await page.getByText(/test complete/).waitFor();
    assert.ok(await page.evaluate(() => window.pauses > 0));
    page.once('dialog', dialog => dialog.dismiss()); await page.getByRole('button', {name: 'Repair USB', exact: true}).click();
    assert.equal(mutations.length, 0);
    page.once('dialog', dialog => dialog.accept()); await page.getByRole('button', {name: 'Repair USB', exact: true}).click();
    await page.getByText('USB gadget rebuilt and verified.', {exact: true}).waitFor();
    assert.deepEqual(mutations[0], {path: '/api/v1/actions/drives/repair', method: 'POST', csrf: '1'});
    await page.screenshot({path: path.join(require('node:os').tmpdir(), 'teslausb-modern-device-tools.png'), fullPage: true});
    failStatus = true;
    await page.getByRole('button', {name: 'Refresh status', exact: true}).click();
    await page.getByText(/Device status unavailable/).waitFor();
    assert.equal(await page.getByRole('button', {name: 'Check USB status first'}).isDisabled(), true);
    await page.evaluate(() => window.openFiles());
    await page.getByText(/Available drives:/).waitFor();
    await page.getByRole('option', {name: 'Song & title.mp3', exact: true}).waitFor();
    assert.equal(await page.getByRole('button', {name: 'Upload files', exact: true}).textContent(), 'Upload');
    await page.getByRole('option', {name: 'Song & title.mp3', exact: true}).click();
    assert.equal(await page.getByRole('button', {name: 'Rename selected item'}).isVisible(), true);
    await page.screenshot({path: path.join(require('node:os').tmpdir(), 'teslausb-modern-files.png'), fullPage: true});
    await page.setViewportSize({width: 390, height: 844});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true, 'Files must fit a phone viewport');
    await page.evaluate(() => window.openDevice());
    await page.getByText(/Device status unavailable/).waitFor();
    await page.getByRole('tab', {name: 'Tools', exact: true}).click();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true, 'Tools must fit a phone viewport');
    await page.evaluate(() => window.active.destroy());
    assert.deepEqual(errors, []);
    console.log('Modern Device/Files browser integration passed (desktop and 390px mobile).');
  } finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
