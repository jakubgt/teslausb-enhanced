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
    const errors = [], mutations = [], requests = [];
    let failStatus = false, powerResponse = 'accepted', sharingMode = 'ready', finishSharingRequest = null, startSharingRequest = null, sharingRequests = 0;
    const sharingText = 'Storage: healthy\nHost: [REDACTED]\n<img src=x onerror="window.sharingInjected=true">\n';
    await page.clock.install();
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/api/v1/**', async route => {
      const request = route.request(), pathname = new URL(request.url()).pathname;
      requests.push({path: pathname, method: request.method()});
      if (pathname === '/api/v1/status') {
        if (failStatus) return route.fulfill({status: 503, body: 'Offline'});
        return route.fulfill({json: {uptime: '90061', total_space: 100000000000, free_space: 20000000000, cpu_temp: '53000', fan_speed: '1200', camera_drive_state: 'connected', drives_active: 'yes', wifi_ssid: 'Garage', wifi_ip: '192.0.2.42', throttled: '0x10000', archive_status: {schema_version: 1, last_result: 'running', pending_files: 3, pending_bytes: 3000, transferred_files: 2, transferred_bytes: 2000}}});
      }
      if (pathname === '/api/v1/maintenance') return route.fulfill({json: {schema_version: 1, ssh: {service_state: 'active', enabled_state: 'enabled'}, health: {schema_version: 1, snapshots: {available: true, scan_complete: true, completed_count: 8, last_completed: {completed_at_utc: '2026-09-08T15:00:00Z'}}, storage: {}, read_only: {root: true, boot: true}}, logs: {diagnostics: {available: true, size_bytes: 24}, archiveloop: {available: true, truncated: true, size_bytes: 10000000}}}});
      if (pathname === '/api/v1/maintenance/logs/diagnostics/shared') {
        sharingRequests++;
        const wasHeld = sharingMode === 'held';
        if (wasHeld) await new Promise(resolve => { finishSharingRequest = resolve; startSharingRequest?.(); });
        try {
          if (sharingMode === 'missing') return await route.fulfill({status: 404, json: {ok: false, error: 'No saved diagnostic report is available.'}});
          return await route.fulfill({json: {ok: true, text: sharingText, filename: sharingMode === 'invalid' ? '../wrong.txt' : 'teslausb-diagnostics-shared.txt', truncated: true, source_bytes_limit: 524288, redactions: {identifiers: 2, credentials: 1}}});
        } catch (error) { if (!wasHeld) throw error; }
        return;
      }
      if (pathname.startsWith('/api/v1/maintenance/logs/')) return route.fulfill({status: 200, contentType: 'text/plain;charset=utf-8', headers: {'X-TeslaUSB-Truncated': pathname.endsWith('archiveloop') ? 'true' : 'false', 'X-TeslaUSB-Original-Size': pathname.endsWith('archiveloop') ? '10000000' : '24'}, body: 'first line\nERROR useful\nlast line\n'});
      if (pathname.startsWith('/api/v1/actions/')) {
        mutations.push({path: pathname, method: request.method(), csrf: request.headers()['x-teslausb-request']});
        if (['/api/v1/actions/shutdown', '/api/v1/actions/reboot'].includes(pathname)) {
          if (powerResponse === 'lost') return route.abort('connectionreset');
          if (powerResponse === 'error') return route.fulfill({status: 503, json: {ok: false, error: 'Fixture could not queue power action'}});
          return route.fulfill({status: 202, json: {ok: true, message: 'Fixture power action queued; completion is not verified'}});
        }
        return route.fulfill({json: {ok: true}});
      }
      if (pathname === '/api/v1/speed-test') return route.fulfill({body: Buffer.alloc(1024), contentType: 'application/octet-stream'});
      if (pathname === '/api/v1/files/list') return route.fulfill({contentType: 'text/plain', body: 'd:Albums\nf:Song & title.mp3:12345\nf:LockChime.wav:400\ns:100000:200000\n'});
      if (pathname === '/api/v1/files/mkdir') { mutations.push({path: pathname, method: request.method(), csrf: request.headers()['x-teslausb-request']}); return route.fulfill({json: {ok: true}}); }
      return route.fulfill({status: 404, body: 'Not in fixture'});
    });
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.getByText(/Status refreshed/).waitFor();
    assert.equal(await page.getByText('Undervoltage occurred since restart', {exact: true}).count(), 1);
    const completedStatusRefresh = () => page.waitForFunction(() => !document.querySelector('[data-device="refresh"]').disabled);
    const countStatusRequests = () => requests.filter(request => request.path === '/api/v1/status').length;
    for (const [idlePanel, statusPanel] of [['Tools', 'Overview'], ['Diagnostics & logs', 'Archive']]) {
      await page.getByRole('tab', {name: idlePanel, exact: true}).click();
      const beforeIdle = countStatusRequests();
      await page.clock.fastForward(35000);
      assert.equal(countStatusRequests(), beforeIdle, `${idlePanel} leaves status polling idle`);
      await page.getByRole('tab', {name: statusPanel, exact: true}).click();
      await completedStatusRefresh();
      assert.equal(countStatusRequests(), beforeIdle + 1, `${statusPanel} fetches fresh status after the previous polling timer expired`);
      await page.clock.fastForward(35000);
      await completedStatusRefresh();
      assert.equal(countStatusRequests(), beforeIdle + 2, `${statusPanel} continues polling after returning from ${idlePanel}`);
    }
    console.log('Status refresh resumes after spending more than 30 seconds in Tools or Logs.');
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
    const modalDownloadEvent = page.waitForEvent('download', {timeout: 5000});
    await page.getByRole('dialog').getByRole('button', {name: 'Download capture', exact: true}).click();
    const modalDownload = await modalDownloadEvent;
    assert.equal(fs.readFileSync(await modalDownload.path(), 'utf8'), 'first line\nERROR useful\nlast line\n', 'Downloading from the full-capture dialog saves the whole captured file despite the search filter');
    await page.getByRole('button', {name: 'Close', exact: true}).click();
    let sharingDownloads = 0;
    page.on('download', () => { sharingDownloads++; });
    const prepareSharing = () => page.getByRole('button', {name: 'Prepare for sharing', exact: true}).click();
    const sharingDialog = () => page.getByRole('dialog', {name: 'Prepare diagnostics for sharing'});
    const sharingPreview = () => page.getByRole('textbox', {name: 'Sharing preview (editable)'});
    await prepareSharing();
    await sharingPreview().waitFor();
    assert.equal(await sharingPreview().inputValue(), sharingText);
    assert.match(await sharingDialog().textContent(), /best effort.*Review this preview/s);
    assert.match(await sharingDialog().textContent(), /latest 512.0 KiB.*earlier content is omitted/s);
    assert.match(await sharingDialog().textContent(), /3 automatic redactions/);
    assert.equal(await sharingDialog().locator('img').count(), 0, 'Diagnostic text is never interpreted as HTML');
    assert.equal(await page.evaluate(() => window.sharingInjected), undefined);
    assert.equal(sharingDownloads, 0, 'Preparing a preview never downloads or uploads it');
    assert.equal(mutations.length, 0, 'Preparing a sharing copy does not regenerate diagnostics');
    assert.deepEqual(requests.filter(request => request.path.endsWith('/diagnostics/shared')).map(request => request.method), ['GET']);
    const reviewedText = 'Storage: healthy\nHost: [REDACTED]\nReviewed note: remaining details removed.\n';
    await sharingPreview().fill(reviewedText);
    await page.evaluate(() => window.active.refresh());
    assert.equal(await sharingPreview().inputValue(), reviewedText, 'A routine health refresh preserves the editable sharing preview');
    await sharingDialog().screenshot({path: path.join(require('node:os').tmpdir(), 'teslausb-diagnostics-sharing-desktop.png')});
    const sharingDownloadEvent = page.waitForEvent('download');
    await page.getByRole('button', {name: 'Download reviewed preview', exact: true}).click();
    const sharingDownload = await sharingDownloadEvent;
    assert.equal(sharingDownload.suggestedFilename(), 'teslausb-diagnostics-shared.txt');
    assert.equal(fs.readFileSync(await sharingDownload.path(), 'utf8'), reviewedText, 'The shared download contains exactly the edited preview');
    const closedPreview = await sharingPreview().elementHandle();
    await page.getByRole('button', {name: 'Close preview', exact: true}).click();
    assert.equal(await closedPreview.evaluate(node => node.value), '', 'Closing wipes the editable copy before removing the dialog');
    assert.equal(await sharingDialog().count(), 0);
    const beforePrepareAgain = sharingRequests;
    await prepareSharing(); await sharingPreview().waitFor();
    assert.equal(sharingRequests, beforePrepareAgain + 1, 'A new preparation fetches current data instead of reusing a previous private preview');
    await page.evaluate(() => document.querySelector('[data-device="log-refresh"]').click());
    assert.equal(await sharingDialog().count(), 0, 'Refreshing the source invalidates the sharing preview');
    sharingMode = 'missing'; await prepareSharing();
    await sharingDialog().getByText(/Could not prepare a sharing preview/).waitFor();
    assert.equal(await sharingDialog().getByRole('button', {name: 'Download reviewed preview'}).isDisabled(), true);
    await page.getByRole('button', {name: 'Close preview', exact: true}).click();
    sharingMode = 'invalid'; await prepareSharing();
    await sharingDialog().getByText(/Unexpected sharing preview/).waitFor();
    assert.equal(await sharingDialog().getByRole('button', {name: 'Download reviewed preview'}).isDisabled(), true);
    await page.getByRole('button', {name: 'Close preview', exact: true}).click();
    sharingMode = 'held'; const heldSharingStarted = new Promise(resolve => { startSharingRequest = resolve; });
    await prepareSharing(); await heldSharingStarted;
    assert.equal(await sharingDialog().getByRole('button', {name: 'Download reviewed preview'}).isDisabled(), true);
    await page.getByRole('button', {name: 'Cancel', exact: true}).click();
    sharingMode = 'ready'; finishSharingRequest();
    await page.waitForFunction(() => !document.querySelector('dialog'));
    assert.equal(sharingDownloads, 1, 'Cancelling never triggers a download');
    sharingMode = 'held'; const timedSharingStarted = new Promise(resolve => { startSharingRequest = resolve; });
    await prepareSharing(); await timedSharingStarted; await page.clock.fastForward(30001);
    await sharingDialog().getByText(/Preparation timed out/).waitFor();
    assert.equal(await sharingDialog().getByRole('button', {name: 'Download reviewed preview'}).isDisabled(), true);
    await page.getByRole('button', {name: 'Close preview', exact: true}).click();
    sharingMode = 'ready'; finishSharingRequest();
    await prepareSharing(); await sharingPreview().waitFor();
    await page.evaluate(() => document.querySelector('[data-device="generate"]').click());
    assert.equal(await sharingDialog().count(), 0, 'Generating a new source report invalidates the sharing preview');
    await page.waitForFunction(() => !document.querySelector('[data-device="generate"]').disabled);
    mutations.length = 0;
    console.log('Sharing diagnostics passed: explicit GET, editable non-HTML preview, truncation notice, exact download, error validation, cancel, wiping and source invalidation.');
    await page.locator('[data-log="archiveloop"]').click();
    assert.equal(await page.getByRole('button', {name: 'Prepare for sharing', exact: true}).isVisible(), false, 'Sharing is offered only for the saved diagnostic report');
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
    await page.waitForFunction(() => !document.querySelector('[data-device="refresh"]').disabled);
    const powerButton = label => page.getByRole('button', {name: label, exact: true});
    const statusRequests = () => requests.filter(request => request.path === '/api/v1/status').length;
    const actionStatus = () => page.locator('[data-device="power-status"]');
    async function confirmPower(label, accept) {
      const dialogEvent = page.waitForEvent('dialog'), click = powerButton(label).click();
      const dialog = await dialogEvent, text = dialog.message();
      assert.match(text, /Pause Dashcam/i);
      if (label === 'Shut down TeslaUSB') assert.match(text, /power cycle/i);
      await (accept ? dialog.accept() : dialog.dismiss()); await click;
      return text;
    }
    async function assertPowerBlocked(blocked) {
      for (const label of ['Reboot TeslaUSB', 'Shut down TeslaUSB', 'Repair USB', 'Run 15-second test']) {
        assert.equal(await powerButton(label).isDisabled(), blocked, `${label} ${blocked ? 'waits for' : 'is available after'} a manual status check`);
      }
    }
    async function checkManualStatus(success = true) {
      failStatus = !success;
      const before = statusRequests();
      await powerButton('Refresh status').click();
      await page.waitForFunction(() => !document.querySelector('[data-device="refresh"]').disabled);
      assert.equal(statusRequests(), before + 1, 'The manual refresh makes one device status request');
      await assertPowerBlocked(!success);
    }

    const beforeCancel = mutations.length;
    await confirmPower('Shut down TeslaUSB', false);
    await confirmPower('Reboot TeslaUSB', false);
    assert.equal(mutations.length, beforeCancel, 'Cancelling either power confirmation sends no mutation');
    await assertPowerBlocked(false);

    const beforeShutdownStatus = statusRequests(), beforeShutdownPauses = await page.evaluate(() => window.pauses);
    await confirmPower('Shut down TeslaUSB', true);
    await actionStatus().filter({hasText: /requested|accepted|queued/i}).waitFor();
    await assertPowerBlocked(true);
    assert.deepEqual(mutations.at(-1), {path: '/api/v1/actions/shutdown', method: 'POST', csrf: '1'});
    assert.ok(await page.evaluate(() => window.pauses) > beforeShutdownPauses, 'Shutdown request releases active media');
    assert.equal(statusRequests(), beforeShutdownStatus, 'Queueing shutdown does not immediately probe device status');
    assert.match(await actionStatus().textContent(), /power cycle/i);
    assert.match(await page.locator('[data-device="status"]').textContent(), /unknown|not verified|not confirmed/i);
    assert.doesNotMatch(await actionStatus().textContent(), /shutdown succeeded|shutdown completed|device (?:is|has) (?:shut down|powered off)/i);
    await page.getByRole('tab', {name: 'Overview', exact: true}).click();
    await page.clock.fastForward(35000);
    assert.equal(statusRequests(), beforeShutdownStatus, 'Polling stays stopped after shutdown, including on Overview');
    await page.evaluate(() => window.openFiles());
    await page.getByText(/Available drives:/).waitFor();
    await page.evaluate(() => window.openDevice());
    await page.getByRole('tab', {name: 'Overview', exact: true}).waitFor();
    assert.match(await page.locator('[data-device="status"]').textContent(), /unknown|not verified|not confirmed|pending/i);
    await page.clock.fastForward(35000);
    assert.equal(statusRequests(), beforeShutdownStatus, 'Remounting Device preserves pending power state without automatic status requests');
    await page.getByRole('tab', {name: 'Tools', exact: true}).click();
    await assertPowerBlocked(true);
    assert.match(await page.locator('[data-device="status"]').textContent(), /manually refreshed|refresh status|check/i, 'The remounted Device retains manual status-check guidance');
    assert.match(await actionStatus().textContent(), /power cycle/i, 'The remounted Power card retains shutdown recovery guidance');
    await checkManualStatus(false);
    await checkManualStatus(true);
    const powerCard = page.locator('.device-card').filter({has: page.getByRole('heading', {name: /^Power/})});
    await powerCard.screenshot({path: path.join(require('node:os').tmpdir(), 'teslausb-modern-device-power-desktop.png')});

    for (const failure of ['error', 'lost']) {
      powerResponse = failure;
      const before = statusRequests();
      await confirmPower('Shut down TeslaUSB', true);
      await actionStatus().filter({hasText: /could not be confirmed|could not confirm|not confirmed/i}).waitFor();
      assert.match(await actionStatus().textContent(), /refresh|check/i);
      assert.doesNotMatch(await actionStatus().textContent(), /shutdown succeeded|shutdown completed|device (?:is|has) (?:shut down|powered off)/i);
      await assertPowerBlocked(true);
      assert.equal(statusRequests(), before, `${failure} response must wait for a manual check`);
      await checkManualStatus(true);
    }
    powerResponse = 'accepted';
    const beforeReboot = statusRequests();
    await confirmPower('Reboot TeslaUSB', true);
    await actionStatus().filter({hasText: /requested|accepted|queued/i}).waitFor();
    assert.deepEqual(mutations.at(-1), {path: '/api/v1/actions/reboot', method: 'POST', csrf: '1'});
    await assertPowerBlocked(true);
    assert.equal(statusRequests(), beforeReboot, 'Reboot also waits for manual status verification');
    await checkManualStatus(true);
    console.log('Power controls passed: cancel, queued shutdown/reboot, CSRF/media pause, no polling, remount persistence, failed/lost response, and manual recovery.');
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
    await page.locator('.device-card').filter({has: page.getByRole('heading', {name: /^Power/})}).screenshot({path: path.join(require('node:os').tmpdir(), 'teslausb-modern-device-power-mobile.png')});
    await page.getByRole('tab', {name: 'Diagnostics & logs', exact: true}).click();
    await prepareSharing(); await sharingPreview().waitFor();
    await sharingPreview().fill(reviewedText);
    assert.equal(await sharingDialog().evaluate(node => node.scrollWidth <= node.clientWidth), true, 'The sharing preview fits a phone viewport');
    await sharingDialog().screenshot({path: path.join(require('node:os').tmpdir(), 'teslausb-diagnostics-sharing-mobile.png')});
    const destroyedPreview = await sharingPreview().elementHandle();
    await page.evaluate(() => window.active.destroy());
    assert.equal(await destroyedPreview.evaluate(node => node.value), '', 'Leaving Device wipes the prepared private copy');
    assert.deepEqual(errors, []);
    console.log('Modern Device/Files browser integration passed (desktop and 390px mobile).');
  } finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
