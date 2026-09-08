/* Device panels use the existing versioned API. Log reads deliberately retain
 * their response headers so a bounded log tail is never described as complete. */
export const DEVICE_LOGS = Object.freeze([
  {id: 'diagnostics', label: 'Diagnostics', filename: 'diagnostics.txt', description: 'The last saved diagnostic report. Generate a fresh report when troubleshooting.'},
  {id: 'archiveloop', label: 'Archive', filename: 'archiveloop.log', description: 'Archive transfers, destination connectivity, and snapshot activity.'},
  {id: 'setup', label: 'Setup', filename: 'teslausb-headless-setup.log', description: 'Installation and configuration history.'},
  {id: 'maintenance', label: 'Maintenance', filename: 'teslausb-runtime-maintenance.log', description: 'Runtime maintenance and recovery activity.'}
]);
const LOG_LIMIT = 8 * 1024 * 1024;

export function formatDeviceBytes(value) {
  if (value === null || value === undefined || value === '' || !Number.isFinite(Number(value)) || Number(value) < 0) return 'Not reported';
  const n = Number(value);
  if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(1)} GiB`;
  if (n >= 1024 ** 2) return `${(n / 1024 ** 2).toFixed(1)} MiB`;
  if (n >= 1024) return `${(n / 1024).toFixed(1)} KiB`;
  return `${n} B`;
}

function timestamp(value) {
  if (!value) return 'Not reported';
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? 'Not reported' : date.toLocaleString();
}

export function archiveDeviceView(system) {
  let status = system?.archive_status;
  if (!status && system && Object.keys(system).some(key => key.startsWith('archive_'))) {
    status = Object.fromEntries(Object.entries(system).filter(([key]) => key.startsWith('archive_')).map(([key, value]) => [key.slice(8), value]));
  }
  if (!status || status.available === false) return {available: false, summary: 'Archive status is not available yet.', message: status?.message || ''};
  if (Number(status.schema_version) !== 1) return {available: false, summary: 'Archive status format is unsupported.', message: 'Update the service and interface together.'};
  const count = key => Math.max(0, Number(status[key]) || 0);
  const pending = count('pending_files'), transferred = count('transferred_files');
  const pendingBytes = count('pending_bytes'), transferredBytes = count('transferred_bytes');
  const state = ['running', 'success', 'error'].includes(status.last_result) ? status.last_result : 'idle';
  const lastSuccess = status.last_successful || status.last_successful_at || status.last_success || (state === 'success' ? status.last_finished : null);
  return {
    available: true, state, pending, transferred, pendingBytes, transferredBytes,
    summary: {running: `Transferring ${transferred} of ${pending + transferred} files`, success: 'Last archive completed', error: 'Last archive failed', idle: pending ? 'Ready to archive' : 'Nothing pending'}[state],
    message: String(status.message || ''), lastSuccess, lastFinished: status.last_finished,
    value: pendingBytes + transferredBytes > 0 ? transferredBytes : transferred,
    max: (pendingBytes + transferredBytes > 0 ? pendingBytes + transferredBytes : pending + transferred) || 1
  };
}

export function devicePowerAlerts(status) {
  const value = String(status?.throttled || '');
  if (!/^(?:0x)?[0-9a-f]+$/i.test(value)) return [];
  const bits = Number.parseInt(value, 16);
  return [[0, 'Undervoltage detected'], [1, 'Processor frequency capped'], [2, 'Processor throttled'], [3, 'Temperature limit active'], [16, 'Undervoltage occurred since restart'], [17, 'Frequency capping occurred since restart'], [18, 'Throttling occurred since restart'], [19, 'Temperature limit occurred since restart']].filter(([bit]) => bits & (1 << bit)).map(([, label]) => label);
}

export function buildDeviceSshCommand(username, hostname, port, keyPath = '') {
  const user = String(username || '').trim();
  let host = String(hostname || '').trim();
  if (!/^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$/.test(user)) throw new Error('Enter a valid SSH username.');
  if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1);
  if (host.includes(':')) {
    if (!/^[0-9a-fA-F:]+$/.test(host)) throw new Error('Enter a valid IPv6 address without a zone suffix.');
    try { host = new URL(`http://[${host}]/`).hostname.slice(1, -1); } catch { throw new Error('Enter a valid IPv6 address.'); }
  } else {
    if (host.length > 253 || !host || !host.split('.').every(label => /^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/.test(label))) throw new Error('Enter a hostname or IP address without a URL or port.');
    if (/^[0-9.]+$/.test(host) && (host.split('.').length !== 4 || !host.split('.').every(part => /^(0|[1-9][0-9]{0,2})$/.test(part) && Number(part) <= 255))) throw new Error('Enter a valid IPv4 address.');
  }
  const portText = String(port || '').trim();
  if (!/^[1-9][0-9]{0,4}$/.test(portText) || Number(portText) > 65535) throw new Error('Enter an SSH port from 1 to 65535.');
  const key = String(keyPath || '').trim();
  if (/[^a-zA-Z0-9 _./\\:()+,@\[\]-]/.test(key) || key.length > 1024 || key && !(/^[a-zA-Z]:[\\/]/.test(key) || /^\/(?!\/)/.test(key))) throw new Error('Use an absolute local key path without quotes or shell symbols.');
  return `ssh -p ${portText}${key ? ` -o IdentitiesOnly=yes -i '${key}'` : ''} ${user}@${host.toLowerCase()}`;
}

export async function readDeviceLog(id, {signal, fetchImpl = fetch} = {}) {
  if (!DEVICE_LOGS.some(log => log.id === id)) throw new Error('Unknown support log.');
  const response = await fetchImpl(`/api/v1/maintenance/logs/${id}`, {signal, cache: 'no-store', headers: {Accept: 'text/plain'}});
  if (!response.ok) throw new Error(response.status === 404 ? 'No saved log is available yet.' : `Could not read the log (HTTP ${response.status}).`);
  const truncated = response.headers.get('X-TeslaUSB-Truncated');
  if (response.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() !== 'text/plain' || !['true', 'false'].includes(truncated)) {
    await response.body?.cancel();
    throw new Error('Unexpected log response. Refresh the dashboard and try again.');
  }
  const reader = response.body?.getReader();
  const chunks = [];
  let size = 0;
  if (reader) {
    try {
      while (true) {
        const {done, value} = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > LOG_LIMIT) throw new Error('The log exceeded the 8 MiB download limit.');
        chunks.push(value);
      }
    } finally { await reader.cancel().catch(() => {}); }
  } else {
    const blob = await response.blob();
    if (blob.size > LOG_LIMIT) throw new Error('The log exceeded the 8 MiB download limit.');
    size = blob.size;
    chunks.push(blob);
  }
  const blob = new Blob(chunks, {type: 'text/plain;charset=utf-8'});
  return {blob, text: await blob.text(), size, truncated: truncated === 'true', originalSize: Number(response.headers.get('X-TeslaUSB-Original-Size')) || size, capturedAt: new Date().toISOString()};
}

function saveBlob(blob, name) {
  const url = URL.createObjectURL(blob), link = document.createElement('a');
  link.href = url; link.download = name; link.hidden = true;
  document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

let pendingPowerAction = null;
export function hasPendingPowerAction() { return pendingPowerAction !== null; }

export function mountDevice(container, {api, onNotice = () => {}}) {
  let destroyed = false, busy = false, powerPending = hasPendingPowerAction(), statusGeneration = 0, status = null, maintenance = null, poll = null, refreshing = null, logGeneration = 0;
  let selectedLog = 'diagnostics', selectedPanel = 'overview', speedController = null, speedTimer = null;
  const controllers = new Set(), logCache = new Map();
  const root = element('div', 'device-root');
  root.innerHTML = `
    <div class="device-heading"><div><p class="device-eyebrow">TESLAUSB</p><h1>Device</h1><p>Health, transfers, and tools in one place.</p></div><button type="button" data-device="refresh">Refresh status</button></div>
    <p class="device-status" data-device="status" role="status" aria-live="polite">Checking device status…</p>
    <div class="device-tabs" role="tablist" aria-label="Device sections">${[['overview', 'Overview'], ['archive', 'Archive'], ['logs', 'Diagnostics & logs'], ['tools', 'Tools']].map(([id, label]) => `<button type="button" role="tab" id="device-tab-${id}" aria-controls="device-panel-${id}" aria-selected="${id === 'overview'}" tabindex="${id === 'overview' ? '0' : '-1'}" data-panel="${id}">${label}</button>`).join('')}</div>
    <section id="device-panel-overview" role="tabpanel" aria-labelledby="device-tab-overview" data-section="overview"><div class="device-alerts" data-device="alerts"></div><div class="device-metrics" data-device="metrics"></div><div class="device-card"><h2>Storage & snapshot health</h2><div data-device="health">Waiting for maintenance status…</div></div></section>
    <section id="device-panel-archive" role="tabpanel" aria-labelledby="device-tab-archive" data-section="archive" hidden><div class="device-card"><div class="device-card-heading"><h2>Archive transfers</h2><button type="button" data-action="sync">Sync now</button></div><div data-device="archive"></div><p data-device="sync-status" role="status"></p></div></section>
    <section id="device-panel-logs" role="tabpanel" aria-labelledby="device-tab-logs" data-section="logs" hidden>
      <div class="device-card-heading"><div><h2>Diagnostics & logs</h2><p>Inspect a captured file, then download exactly what you viewed.</p></div><button type="button" data-device="bundle">Download support bundle</button></div>
      <div class="device-log-layout"><div class="device-log-list" aria-label="Log sections">${DEVICE_LOGS.map(log => `<button type="button" data-log="${log.id}" aria-pressed="${log.id === selectedLog}"><strong>${log.label}</strong><span data-log-info="${log.id}">Availability not checked</span></button>`).join('')}</div><div class="device-card device-log-card">
        <div class="device-card-heading"><div><h3 data-device="log-title">Diagnostics</h3><p data-device="log-description"></p></div><button type="button" data-device="generate">Generate fresh diagnostics</button></div>
        <div class="device-log-toolbar"><label>Search this capture<input type="search" data-device="search" placeholder="Find text in log"></label><label class="device-checkbox"><input type="checkbox" data-device="wrap" checked> Wrap lines</label><button type="button" data-device="log-refresh">Refresh saved file</button><button type="button" data-device="log-full">View full capture</button><button type="button" data-device="log-download">Download capture</button></div>
        <p class="device-status" data-device="log-status" role="status" aria-live="polite">Select a log to load its saved file.</p><pre tabindex="0" class="device-log-text device-wrap" data-device="log-text" aria-label="Captured log"></pre>
      </div></div><p class="device-status" data-device="bundle-status" role="status"></p>
    </section>
    <section id="device-panel-tools" role="tabpanel" aria-labelledby="device-tab-tools" data-section="tools" hidden>
      <div class="device-tools-grid"><div class="device-card"><h2>Network speed test</h2><p>Measure the connection from TeslaUSB to this browser. Playback pauses for the test.</p><button type="button" data-device="speed">Run 15-second test</button><p class="device-status" data-device="speed-status" role="status">Ready when you are.</p></div>
      <div class="device-card"><h2>USB drives</h2><p data-device="drive-state">Checking USB connection…</p><p>Pause Dashcam in your vehicle before disconnecting or repairing the drives.</p><div class="device-actions"><button type="button" data-action="toggle" disabled>Check USB status first</button><button type="button" data-action="repair">Repair USB</button></div></div>
      <div class="device-card"><h2>Power</h2><p>Pause Dashcam and finish file transfers or archive work before either action.</p><p>Reboot restarts TeslaUSB. Shutdown takes it offline; turning it on again requires a power cycle.</p><div class="device-actions"><button type="button" data-action="reboot">Reboot TeslaUSB</button><button type="button" class="device-danger" data-action="shutdown">Shut down TeslaUSB</button></div><p class="device-status" data-device="power-status" role="status" aria-live="polite"></p></div>
      <div class="device-card"><h2>SSH help</h2><p data-device="ssh-status">SSH service status has not been checked.</p><p>Build a command to run in your own terminal. These fields stay in this page and are never stored.</p>
        <div class="device-ssh-fields"><label>Username<input data-ssh="user" value="pi" autocomplete="off" spellcheck="false"></label><label>Hostname or IP<input data-ssh="host" autocomplete="off" spellcheck="false"></label><label>Port<input data-ssh="port" value="22" inputmode="numeric" autocomplete="off"></label><label>Local key path (optional)<input data-ssh="key" placeholder="/home/me/.ssh/id_ed25519" autocomplete="off" spellcheck="false"></label></div>
        <label class="device-command">Terminal command<input data-device="ssh-command" readonly spellcheck="false"></label><button type="button" data-device="ssh-copy">Copy command</button><p data-device="ssh-help" class="device-status" role="status"></p>
      </div></div><p class="device-status" data-device="action-status" role="status" aria-live="polite"></p>
    </section>`;
  container.replaceChildren(root);
  const find = key => root.querySelector(`[data-device="${key}"]`);
  const say = (key, message, error = false) => { const node = find(key); node.textContent = message; node.classList.toggle('device-error', error); };
  const request = async (path, options = {}, timeout = 30000) => {
    const controller = new AbortController(); controllers.add(controller);
    const timer = setTimeout(() => controller.abort(), timeout);
    try { return await api(path, {...options, signal: controller.signal}); }
    finally { clearTimeout(timer); controllers.delete(controller); }
  };
  const isValid = value => value !== '' && value !== null && value !== undefined && value !== 'N/A' && Number.isFinite(Number(value));
  function metric(label, value, detail) {
    const card = element('div', 'device-card device-metric');
    card.append(element('span', 'device-muted', label), element('strong', '', value));
    if (detail) card.append(element('span', 'device-muted', detail));
    return card;
  }
  function showStatus() {
    const s = status || {};
    const total = Number(s.total_space), free = Number(s.free_space);
    const storageKnown = isValid(s.total_space) && isValid(s.free_space) && total > 0;
    const uptime = isValid(s.uptime) ? `${Math.floor(Number(s.uptime) / 86400)}d ${Math.floor(Number(s.uptime) % 86400 / 3600)}h ${Math.floor(Number(s.uptime) % 3600 / 60)}m` : 'Not reported';
    find('metrics').replaceChildren(metric('Storage free', storageKnown ? formatDeviceBytes(free) : 'Not reported', storageKnown ? `of ${formatDeviceBytes(total)} · ${Math.round((total - free) / total * 100)}% used` : ''), metric('Core temperature', isValid(s.cpu_temp) ? `${(Number(s.cpu_temp) / 1000).toFixed(1)} °C` : 'Not reported', isValid(s.fan_speed) ? `Fan ${s.fan_speed} RPM` : ''), metric('Uptime', uptime, isValid(s.external_5v) ? `Supply ${Number(s.external_5v).toFixed(3)} V` : ''), metric('Network', s.wifi_ssid || (s.ether_ip ? 'Ethernet' : 'Not reported'), [s.wifi_ip, s.ether_ip].filter(Boolean).join(' · ')));
    const warnings = devicePowerAlerts(s);
    if (storageKnown && free / total < 0.1) warnings.push('Storage is below 10% free. Check archive progress and retention.');
    if (isValid(s.cpu_temp) && Number(s.cpu_temp) >= 80000) warnings.push('Core temperature is high. Check cooling.');
    if (s.encrypted_clips?.available !== false && s.encrypted_clips?.detected === true) warnings.push('Encrypted recordings detected. TeslaUSB preserves them but cannot play or archive them. View them in the recording vehicle or its linked Tesla account.');
    find('alerts').replaceChildren(...warnings.map(message => element('p', 'device-alert', message)));
    const driveLabels = {disabled: 'USB drives are disabled.', prepared: 'USB prepared; no host connection.', paused: 'Camera image is temporarily detached.', unavailable: 'Camera image is not attached.', connected: 'Camera drive is connected to the host.', suspended: 'The host suspended the USB connection.', disconnected: 'Waiting for a USB host.', connecting: 'USB connection is in progress.', unknown: 'USB connection status is unavailable.'};
    say('drive-state', driveLabels[s.camera_drive_state] || driveLabels.unknown);
    const toggle = root.querySelector('[data-action="toggle"]');
    toggle.disabled = busy || powerPending || !['yes', 'no'].includes(s.drives_active);
    toggle.textContent = s.drives_active === 'yes' ? 'Disconnect USB drives' : s.drives_active === 'no' ? 'Connect USB drives' : 'Check USB status first';
    const archive = archiveDeviceView(status), holder = find('archive');
    holder.replaceChildren(element('h3', archive.state === 'error' ? 'device-error' : '', archive.summary));
    if (archive.available) {
      const grid = element('div', 'device-archive-stats');
      grid.append(metric('Pending', `${archive.pending} files`, formatDeviceBytes(archive.pendingBytes)), metric('Transferred', `${archive.transferred} files`, formatDeviceBytes(archive.transferredBytes)), metric('Last successful archive', timestamp(archive.lastSuccess)));
      holder.append(grid);
      if (archive.state === 'running') {
        const progress = element('progress'); progress.max = archive.max; progress.value = archive.value; progress.setAttribute('aria-label', 'Archive transfer progress'); holder.append(progress);
      }
      if (!archive.lastSuccess && archive.lastFinished) holder.append(element('p', 'device-muted', `Last attempt finished ${timestamp(archive.lastFinished)}. Earlier success is not reported by this service.`));
    }
    if (archive.message) holder.append(element('p', archive.state === 'error' ? 'device-error' : 'device-muted', archive.message));
    root.querySelector('[data-action="sync"]').disabled = busy || powerPending || archive.state === 'running';
  }
  function showMaintenance() {
    const health = maintenance?.health;
    const holder = find('health'); holder.replaceChildren();
    if (!health || health.schema_version !== 1) holder.append(element('p', 'device-muted', 'Detailed health is unavailable. Refresh status to try again.'));
    else {
      const rows = [];
      for (const [key, label] of [['backing', 'Recording storage'], ['mutable', 'Log storage']]) {
        const disk = health.storage?.[key];
        rows.push([label, disk?.available ? `${formatDeviceBytes(disk.free_bytes)} free of ${formatDeviceBytes(disk.total_bytes)}` : 'Not reported']);
        if (disk?.below_cleanup_reserve === true) holder.append(element('p', 'device-alert', 'Recording storage is below its cleanup reserve. Check snapshot cleanup and archive progress.'));
      }
      const snap = health.snapshots;
      rows.push(['Last completed snapshot', snap?.available && snap.scan_complete ? timestamp(snap.last_completed?.completed_at_utc) : 'Not verified']);
      rows.push(['Completed snapshots', snap?.available && snap.scan_complete ? String(snap.completed_count ?? 'Not reported') : 'Not verified']);
      rows.push(['Clock', health.clock?.available ? `${String(health.clock.state || 'Not reported').replaceAll('_', ' ')} · verified ${timestamp(health.clock.last_verified_utc)}` : 'Not verified']);
      const cleanup = health.cleanup;
      rows.push(['Snapshot cleanup', cleanup?.evidence === 'completed_release' ? `Release reported ${timestamp(cleanup.last_released_at_utc)} (retained log evidence)` : cleanup?.evidence === 'release_attempt' ? 'Attempt seen; completion is not established in the retained log' : 'Completion is not established in the retained log']);
      const recovery = health.recovery;
      rows.push(['Recovery backups', recovery?.available && recovery.scan_complete ? `${recovery.items?.length || 0} bundles · ${formatDeviceBytes(recovery.total_logical_bytes)} logical size; shared extents may overlap and this is not reclaimable space` : 'Inventory unavailable or incomplete']);
      rows.push(['Root / boot mode', `${health.read_only?.root == null ? 'Unknown' : health.read_only?.root === true ? 'Read only' : 'Writable'} / ${health.read_only?.boot == null ? 'Unknown' : health.read_only?.boot === true ? 'Read only' : 'Writable'}`]);
      const list = element('dl', 'device-health-list');
      for (const [label, value] of rows) list.append(element('dt', '', label), element('dd', '', value));
      holder.append(list);
    }
    const ssh = maintenance?.ssh;
    say('ssh-status', ssh ? `SSH service: ${ssh.service_state || 'unknown'} · startup: ${ssh.enabled_state || 'unknown'}. Login and port reachability are not verified.` : 'SSH service state is unavailable.');
    for (const log of DEVICE_LOGS) {
      const info = maintenance?.logs?.[log.id];
      const label = root.querySelector(`[data-log-info="${log.id}"]`);
      label.textContent = info?.available === true ? `${formatDeviceBytes(info.size_bytes)}${info.truncated ? ' · latest 8 MiB only' : ' · saved file'}` : info?.available === false ? (info.reason === 'missing' ? 'No saved file yet' : 'Currently unavailable') : 'Availability not checked';
    }
  }
  async function refresh() {
    if (destroyed || (busy && powerPending)) return;
    if (refreshing) return refreshing;
    const generation = statusGeneration;
    find('refresh').disabled = true;
    say('status', 'Refreshing device and maintenance status…');
    refreshing = (async () => {
      const results = await Promise.allSettled([request('/api/v1/status'), request('/api/v1/maintenance')]);
      if (destroyed || generation !== statusGeneration) return;
      const errors = [];
      status = results[0].status === 'fulfilled' ? results[0].value : null;
      if (status && powerPending) { powerPending = false; pendingPowerAction = null; say('power-status', 'The device responded to this status check. Power-action completion is not verified.'); }
      maintenance = results[1].status === 'fulfilled' && results[1].value?.schema_version === 1 ? results[1].value : null;
      if (!status) errors.push(`Device status unavailable: ${results[0].reason?.message || 'invalid response'}`);
      if (!maintenance) errors.push(`Maintenance status unavailable: ${results[1].reason?.message || 'invalid response'}`);
      updateBusy(); showMaintenance();
      say('status', errors.length ? errors.join(' · ') : `Status refreshed ${new Date().toLocaleTimeString()} (this browser).`, errors.length > 0);
    })().finally(() => {
      refreshing = null;
      if (!destroyed) { updateBusy(); clearTimeout(poll); if (!powerPending) poll = setTimeout(() => { if (selectedPanel === 'archive' || selectedPanel === 'overview') void refresh(); }, 30000); }
    });
    return refreshing;
  }
  function selectPanel(id) {
    selectedPanel = id;
    if (id !== 'tools') stopSpeed('Speed test stopped.');
    root.querySelectorAll('[data-panel]').forEach(button => { const selected = button.dataset.panel === id; button.setAttribute('aria-selected', String(selected)); button.tabIndex = selected ? 0 : -1; });
    root.querySelectorAll('[data-section]').forEach(section => { section.hidden = section.dataset.section !== id; });
    if (id === 'logs') void loadLog(selectedLog);
  }
  function renderLog() {
    const info = DEVICE_LOGS.find(log => log.id === selectedLog), capture = logCache.get(selectedLog);
    say('log-title', info.label); say('log-description', info.description);
    find('generate').hidden = selectedLog !== 'diagnostics';
    root.querySelectorAll('[data-log]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.log === selectedLog)));
    find('log-full').disabled = !capture; find('log-download').disabled = !capture;
    const search = find('search').value.toLocaleLowerCase();
    find('log-text').classList.toggle('device-wrap', find('wrap').checked);
    if (!capture) { say('log-text', ''); return; }
    const lines = capture.text.split('\n'), filtered = search ? lines.filter(line => line.toLocaleLowerCase().includes(search)) : lines;
    say('log-text', filtered.join('\n') || (search ? 'No matching lines in this capture.' : 'This captured file is empty.'));
    say('log-status', `${capture.truncated ? `Only the latest 8 MiB of ${formatDeviceBytes(capture.originalSize)} were captured. Earlier content is unavailable here.` : 'Complete saved file captured.'} ${formatDeviceBytes(capture.size)} · captured ${timestamp(capture.capturedAt)}${search ? ` · ${filtered.length} matching lines; downloads include the whole capture` : ''}`);
  }
  async function fetchLog(id) {
    const controller = new AbortController(); controllers.add(controller);
    const timer = setTimeout(() => controller.abort(), 15000);
    try { return await readDeviceLog(id, {signal: controller.signal}); }
    finally { clearTimeout(timer); controllers.delete(controller); }
  }
  async function loadLog(id, force = false) {
    selectedLog = id; const generation = ++logGeneration;
    if (force) logCache.delete(id);
    renderLog();
    if (logCache.has(id)) return;
    say('log-status', 'Loading saved file…');
    try {
      const result = await fetchLog(id);
      if (destroyed) return;
      logCache.set(id, result);
      if (generation === logGeneration) renderLog();
    } catch (error) { if (!destroyed && generation === logGeneration) say('log-status', error.name === 'AbortError' ? 'Log request timed out or was cancelled. Use Refresh saved file to retry.' : error.message, true); }
  }
  async function generateDiagnostics() {
    if (busy || powerPending) return;
    busy = true; updateBusy();
    say('log-status', 'Generating fresh diagnostics. This can take up to two minutes…');
    try {
      await request('/api/v1/actions/diagnostics', {method: 'POST', headers: {'X-TeslaUSB-Request': '1'}}, 120000);
      if (destroyed) return;
      logCache.delete('diagnostics');
      await loadLog('diagnostics', true);
      onNotice('Fresh diagnostics generated.');
    } catch (error) { if (!destroyed) say('log-status', `Could not generate diagnostics: ${error.message}. The previous saved report has not been replaced in this view.`, true); }
    finally { busy = false; if (!destroyed) updateBusy(); }
  }
  function fullLog() {
    const capture = logCache.get(selectedLog); if (!capture) return;
    const info = DEVICE_LOGS.find(log => log.id === selectedLog), dialog = element('dialog', 'device-log-dialog');
    const heading = element('div', 'device-card-heading'), close = element('button', '', 'Close'), download = element('button', '', 'Download capture');
    close.type = download.type = 'button';
    heading.append(element('h2', '', `${info.label} · full capture`), download, close);
    const pre = element('pre', `device-log-text ${find('wrap').checked ? 'device-wrap' : ''}`, capture.text || 'This captured file is empty.');
    pre.tabIndex = 0;
    dialog.append(heading, element('p', 'device-status', capture.truncated ? 'This is the entire captured tail (latest 8 MiB). Earlier log content is not included.' : `Entire saved file captured ${timestamp(capture.capturedAt)}.`), pre);
    download.addEventListener('click', () => saveBlob(capture.blob, `${capture.truncated ? 'latest-tail-' : ''}${info.filename}`));
    close.addEventListener('click', () => dialog.close());
    dialog.addEventListener('close', () => dialog.remove());
    root.append(dialog); dialog.showModal();
  }
  async function downloadBundle() {
    find('bundle').disabled = true; say('bundle-status', 'Preparing saved logs and current status…');
    const parts = [`TeslaUSB support capture\nCaptured by this browser: ${new Date().toISOString()}\nSaved diagnostic reports are not regenerated automatically.\n`];
    let included = 0;
    try {
      for (const info of DEVICE_LOGS) {
        if (destroyed) return;
        try { const capture = await fetchLog(info.id); logCache.set(info.id, capture); parts.push(`\n===== ${info.filename} =====\n${capture.truncated ? 'TRUNCATED: only the latest 8 MiB. Earlier content omitted.' : 'Complete saved file.'}\nCaptured: ${capture.capturedAt}\n\n`, capture.text, '\n'); included++; }
        catch (error) { if (destroyed) return; parts.push(`\n===== ${info.filename} =====\nUnavailable: ${error.message}\n`); }
      }
      parts.push('\n===== Last fetched status =====\n', JSON.stringify({device: status, maintenance}, null, 2));
      if (!included) throw new Error('No saved logs could be fetched. Refresh status and retry.');
      saveBlob(new Blob(parts, {type: 'text/plain;charset=utf-8'}), `teslausb-support-${new Date().toISOString().slice(0, 10)}.txt`);
      say('bundle-status', `Downloaded a support text bundle with ${included} of ${DEVICE_LOGS.length} saved files. Any missing files and truncated captures are identified inside.`);
      renderLog();
    } catch (error) { if (!destroyed) say('bundle-status', error.message, true); }
    finally { if (!destroyed) find('bundle').disabled = false; }
  }
  function stopSpeed(message) {
    if (!speedController) return;
    speedController.abort(); speedController = null; clearTimeout(speedTimer);
    if (!destroyed) { find('speed').textContent = 'Run 15-second test'; say('speed-status', message); }
    window.dispatchEvent(new CustomEvent('teslausb:speed-test', {detail: {active: false}}));
  }
  async function speedTest() {
    if (powerPending || busy) return;
    if (speedController) { stopSpeed('Speed test cancelled.'); return; }
    window.dispatchEvent(new CustomEvent('teslausb:pause-media'));
    window.dispatchEvent(new CustomEvent('teslausb:speed-test', {detail: {active: true}}));
    const controller = new AbortController(); speedController = controller;
    find('speed').textContent = 'Cancel speed test'; say('speed-status', 'Starting network test…');
    const start = performance.now(); let bytes = 0;
    const reading = () => `${((bytes * 8) / Math.max(1, performance.now() - start) / 1000).toFixed(1)} Mbps average · ${formatDeviceBytes(bytes)} received`;
    speedTimer = setTimeout(() => stopSpeed(`${reading()} · 15-second test complete.`), 15000);
    try {
      const response = await fetch('/api/v1/speed-test?15', {signal: controller.signal, cache: 'no-store'});
      if (!response.ok || response.headers.get('Content-Type')?.split(';')[0].trim() !== 'application/octet-stream') throw new Error(`Unexpected speed-test response (HTTP ${response.status}).`);
      const reader = response.body?.getReader();
      if (!reader) throw new Error('Streaming responses are not supported by this browser.');
      try {
        while (!controller.signal.aborted) {
          const {done, value} = await reader.read(); if (done) break;
          bytes += value.byteLength;
          if (!destroyed && speedController === controller) say('speed-status', reading());
        }
      } finally { await reader.cancel().catch(() => {}); }
      if (speedController === controller) stopSpeed(`${reading()} · test complete.`);
    } catch (error) { if (speedController === controller) stopSpeed(error.name === 'AbortError' ? 'Speed test cancelled.' : `Speed test failed: ${error.message}`); }
  }
  function updateBusy() {
    root.querySelectorAll('[data-action]').forEach(button => { button.disabled = busy || powerPending; });
    find('generate').disabled = busy || powerPending;
    find('speed').disabled = busy || powerPending;
    find('refresh').disabled = busy || !!refreshing;
    showStatus();
  }
  async function action(id) {
    if (busy || powerPending) return;
    const isPower = id === 'reboot' || id === 'shutdown';
    const settings = {
      sync: {path: 'sync', message: 'Archive sync requested. Transfer progress will appear when the archive service starts.'},
      toggle: {path: 'drives/toggle', confirm: status?.drives_active === 'yes' ? 'Disconnect all USB drives? Pause Dashcam in your vehicle first. Recording to these drives stops until they reconnect.' : 'Connect USB drives to the vehicle?', message: 'USB action completed. Checking the actual connection state…'},
      repair: {path: 'drives/repair', confirm: 'Repair the USB connection? Pause Dashcam first. This briefly disconnects every virtual drive while the USB gadget is rebuilt and verified.', message: 'USB gadget rebuilt and verified.'},
      reboot: {path: 'reboot', confirm: 'Reboot TeslaUSB? Pause Dashcam first. Recording access, playback, uploads, and archive work will be interrupted. The device will restart.', message: 'Reboot queued. The device may be unreachable for a moment. Use Refresh status after it returns.'},
      shutdown: {path: 'shutdown', confirm: 'Shut down TeslaUSB? Pause Dashcam first and finish file transfers or archive work. Recording access will stop. Turning the Pi on again requires a power cycle; this page cannot turn it back on. Continue?', message: 'Shutdown queued. Wait for the Pi to finish shutting down before disconnecting power. Turning it on again requires a power cycle.'}
    }[id];
    if (!settings || id === 'toggle' && !['yes', 'no'].includes(status?.drives_active)) return;
    if (settings.confirm && !window.confirm(settings.confirm)) return;
    busy = true;
    if (isPower) { powerPending = true; pendingPowerAction = {message: 'A power action was requested. Use Refresh status to check the connection before continuing.', error: false}; statusGeneration++; clearTimeout(poll); controllers.forEach(controller => controller.abort()); }
    updateBusy(); stopSpeed('Speed test stopped for device action.');
    if (id !== 'sync') window.dispatchEvent(new CustomEvent('teslausb:pause-media'));
    const key = isPower ? 'power-status' : id === 'sync' ? 'sync-status' : 'action-status'; say(key, 'Request in progress…');
    try {
      const result = await request(`/api/v1/actions/${settings.path}`, {method: 'POST', headers: {'X-TeslaUSB-Request': '1'}}, id === 'repair' ? 60000 : 30000);
      if (result?.ok === false) throw new Error(result.error || 'The device rejected the action.');
      if (isPower && pendingPowerAction) pendingPowerAction = {message: settings.message, error: false};
      if (destroyed) return;
      say(key, settings.message); onNotice(settings.message);
      if (!isPower) await refresh();
      else { status = null; maintenance = null; showStatus(); showMaintenance(); say('status', `${id === 'shutdown' ? 'Shutdown' : 'Reboot'} requested. Current device status is unknown until refreshed.`); }
    } catch (error) { const message = `Action could not be confirmed: ${error.message}. Refresh status before retrying.`; if (isPower && pendingPowerAction) pendingPowerAction = {message, error: true}; if (!destroyed) { say(key, message, true); if (isPower) { status = null; maintenance = null; showStatus(); showMaintenance(); say('status', 'Power-action result is unknown. Use Refresh status to check the connection before retrying.', true); } } }
    finally { busy = false; if (!destroyed) updateBusy(); }
  }
  function updateSsh() {
    const value = key => root.querySelector(`[data-ssh="${key}"]`).value;
    try { find('ssh-command').value = buildDeviceSshCommand(value('user'), value('host'), value('port'), value('key')); find('ssh-copy').disabled = false; say('ssh-help', 'Port 22 is a default suggestion. This command has not been tested.'); }
    catch (error) { find('ssh-command').value = ''; find('ssh-copy').disabled = true; say('ssh-help', error.message, true); }
  }
  root.querySelector('[data-ssh="host"]').value = window.location.hostname;
  root.querySelectorAll('[data-ssh]').forEach(field => field.addEventListener('input', updateSsh));
  updateSsh();
  find('ssh-copy').addEventListener('click', async () => {
    const field = find('ssh-command');
    try { await navigator.clipboard.writeText(field.value); say('ssh-help', 'Command copied. Run it in your terminal.'); }
    catch { field.focus(); field.select(); say('ssh-help', 'The command is selected. Press Ctrl+C or Command+C, or use your device’s Copy action.'); }
  });
  root.querySelectorAll('[data-panel]').forEach(button => button.addEventListener('click', () => selectPanel(button.dataset.panel)));
  root.querySelector('.device-tabs').addEventListener('keydown', event => {
    const tabs = [...root.querySelectorAll('[data-panel]')], current = tabs.indexOf(document.activeElement);
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key) || current < 0) return;
    event.preventDefault();
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (current + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
    tabs[next].focus(); selectPanel(tabs[next].dataset.panel);
  });
  root.querySelectorAll('[data-log]').forEach(button => button.addEventListener('click', () => { find('search').value = ''; void loadLog(button.dataset.log); }));
  root.querySelectorAll('[data-action]').forEach(button => button.addEventListener('click', () => void action(button.dataset.action)));
  find('refresh').addEventListener('click', () => void refresh());
  find('log-refresh').addEventListener('click', () => void loadLog(selectedLog, true));
  find('search').addEventListener('input', renderLog); find('wrap').addEventListener('change', renderLog);
  find('generate').addEventListener('click', () => void generateDiagnostics()); find('log-full').addEventListener('click', fullLog);
  find('log-download').addEventListener('click', () => { const capture = logCache.get(selectedLog), info = DEVICE_LOGS.find(log => log.id === selectedLog); if (capture) saveBlob(capture.blob, `${capture.truncated ? 'latest-tail-' : ''}${info.filename}`); });
  find('bundle').addEventListener('click', () => void downloadBundle()); find('speed').addEventListener('click', () => void speedTest());
  if (powerPending) { updateBusy(); showMaintenance(); say('power-status', pendingPowerAction.message, pendingPowerAction.error); say('status', 'A power action was requested. Current device status is unknown until manually refreshed.'); }
  else void refresh();
  return {refresh, destroy() { destroyed = true; clearTimeout(poll); stopSpeed(''); controllers.forEach(controller => controller.abort()); controllers.clear(); root.querySelectorAll('dialog').forEach(dialog => dialog.close()); logCache.clear(); root.remove(); }};
}
