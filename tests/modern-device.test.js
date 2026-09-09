'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function run() {
  const moduleSource = fs.readFileSync(path.join(__dirname, '../teslausb-www/html/modern/device.js'), 'utf8');
  const filesSource = fs.readFileSync(path.join(__dirname, '../teslausb-www/html/modern/files.js'), 'utf8');
  const device = await import('data:text/javascript;base64,' + Buffer.from(moduleSource).toString('base64'));
  const files = await import('data:text/javascript;base64,' + Buffer.from(filesSource).toString('base64'));
  const {archiveDeviceView, buildDeviceSshCommand, devicePowerAlerts, formatDeviceBytes, readDeviceLog} = device;

  assert.equal(archiveDeviceView({}).available, false);
  assert.equal(archiveDeviceView({archive_status: {available: false}}).available, false);
  assert.equal(archiveDeviceView({archive_status: {schema_version: 2}}).available, false);
  const running = archiveDeviceView({archive_status: {schema_version: 1, last_result: 'running', transferred_files: '3', pending_files: '2', transferred_bytes: 600, pending_bytes: 400}});
  assert.equal(running.summary, 'Transferring 3 of 5 files');
  assert.equal(running.value, 600); assert.equal(running.max, 1000);
  const failed = archiveDeviceView({archive_status: {schema_version: 1, last_result: 'error', last_finished: '2026-09-08T12:00:00Z'}});
  assert.equal(failed.lastSuccess, null, 'A failed attempt must never be shown as a successful archive');
  const success = archiveDeviceView({archive_status: {schema_version: 1, last_result: 'success', last_finished: '2026-09-08T12:00:00Z'}});
  assert.equal(success.lastSuccess, '2026-09-08T12:00:00Z');
  assert.equal(archiveDeviceView({archive_schema_version: 1, archive_last_result: 'error'}).state, 'error');
  assert.deepEqual(devicePowerAlerts({throttled: '0x10001'}), ['Undervoltage detected', 'Undervoltage occurred since restart']);
  assert.deepEqual(devicePowerAlerts({throttled: 'N/A'}), []);
  assert.equal(formatDeviceBytes(null), 'Not reported'); assert.equal(formatDeviceBytes(''), 'Not reported'); assert.equal(formatDeviceBytes(0), '0 B');
  assert.deepEqual(files.configuredFileDrives({has_music: 'yes', has_cam: 'yes', has_boombox: 'yes'}), [{path: 'fs/Music', label: 'Music'}, {path: 'fs/Boombox', label: 'Boombox'}]);
  assert.deepEqual(files.configuredFileDrives({has_music: 'no'}), []);

  assert.equal(buildDeviceSshCommand('pi', 'TeslaUSB.local', 22), 'ssh -p 22 pi@teslausb.local');
  assert.equal(buildDeviceSshCommand('pi', '[2001:db8::1]', 2222, 'C:\\Users\\A User\\.ssh\\key'), "ssh -p 2222 -o IdentitiesOnly=yes -i 'C:\\Users\\A User\\.ssh\\key' pi@2001:db8::1");
  for (const host of ['https://teslausb.local', '-oProxyCommand=x', 'host;id', '999.1.2.3', '1.2.3', '01.2.3.4', 'fe80::1%eth0', 'host:22', ':::']) assert.throws(() => buildDeviceSshCommand('pi', host, 22));
  for (const key of ['/tmp/$(id)', '/tmp/`id`', "/tmp/key' -oProxyCommand=x", '/tmp/\u2019key', '/tmp/key\nvalue', 'relative/key', '//host/key']) assert.throws(() => buildDeviceSshCommand('pi', 'teslausb.local', 22, key));
  for (const user of ['-oProxyCommand=x', 'pi;id', 'pi@other', 'pi\nother']) assert.throws(() => buildDeviceSshCommand(user, 'teslausb.local', 22));
  for (const port of [0, 65536, '022', '22;id']) assert.throws(() => buildDeviceSshCommand('pi', 'teslausb.local', port));

  const response = (body, extra = {}, status = 200) => new Response(body, {status, headers: {'Content-Type': 'text/plain;charset=utf-8', 'X-TeslaUSB-Truncated': 'false', ...extra}});
  let called;
  const capture = await readDeviceLog('diagnostics', {fetchImpl: async (url, options) => { called = {url, options}; return response('hello\nworld'); }});
  assert.equal(called.url, '/api/v1/maintenance/logs/diagnostics');
  assert.equal(called.options.cache, 'no-store');
  assert.equal(capture.text, 'hello\nworld'); assert.equal(capture.truncated, false); assert.equal(capture.size, 11);
  const tail = await readDeviceLog('maintenance', {fetchImpl: async () => response('tail', {'X-TeslaUSB-Truncated': 'true', 'X-TeslaUSB-Original-Size': '10000000'})});
  assert.equal(tail.truncated, true); assert.equal(tail.originalSize, 10000000);
  await assert.rejects(readDeviceLog('../credentials', {fetchImpl: () => { throw new Error('must not fetch'); }}), /Unknown support log/);
  await assert.rejects(readDeviceLog('setup', {fetchImpl: async () => response('missing', {}, 404)}), /No saved log/);
  await assert.rejects(readDeviceLog('setup', {fetchImpl: async () => response('<html>Login</html>', {'Content-Type': 'text/html'})}), /Unexpected log response/);
  await assert.rejects(readDeviceLog('setup', {fetchImpl: async () => response('log', {'X-TeslaUSB-Truncated': 'maybe'})}), /Unexpected log response/);
  await assert.rejects(readDeviceLog('setup', {fetchImpl: async () => response(new Uint8Array(8 * 1024 * 1024 + 1))}), /8 MiB download limit/);
  console.log('Modern Device/Files behavior tests passed.');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
