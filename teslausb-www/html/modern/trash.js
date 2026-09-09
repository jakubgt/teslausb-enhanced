const byteCount = value => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : null;
const size = value => {
  if (byteCount(value) === null) return 'Not reported';
  const power = value ? Math.min(4, Math.floor(Math.log(value) / Math.log(1024))) : 0;
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(value / 1024 ** power) + ' ' + ['B', 'KiB', 'MiB', 'GiB', 'TiB'][power];
};
const recordingCount = value => value === null ? 'Recording count not reported' : `${value} recording${value === 1 ? '' : 's'}`;
const stamp = value => new Date(value).toLocaleString();
const cameraName = name => ({ front: 'Front', back: 'Rear', left_repeater: 'Left repeater', right_repeater: 'Right repeater', left_pillar: 'Left pillar', right_pillar: 'Right pillar' }[name] || name);

export function trashStorageView(value) {
  const source = value && typeof value === 'object' ? value : {};
  const group = entries => {
    if (!Array.isArray(entries)) return { count: null, bytes: null, ids: [] };
    const ids = entries.map(entry => entry && typeof entry === 'object' && typeof entry.id === 'string' ? entry.id : null);
    if (ids.some(id => !id) || new Set(ids).size !== ids.length) return { count: null, bytes: null, ids: [] };
    const amounts = entries.map(entry => byteCount(entry.bytes));
    const total = amounts.includes(null) ? null : amounts.reduce((sum, bytes) => sum + bytes, 0);
    return { count: entries.length, bytes: byteCount(total), ids };
  };
  const trash = group(source.items), restored = group(source.restored);
  const retainedBytes = byteCount(source.retained_bytes), freeBytes = byteCount(source.free_bytes), reserveBytes = byteCount(source.reserve_bytes);
  const sharedIds = new Set(trash.ids);
  const overlap = restored.ids.some(id => sharedIds.has(id));
  const combined = trash.bytes !== null && restored.bytes !== null ? byteCount(trash.bytes + restored.bytes) : null;
  const inconsistent = overlap || (combined !== null && retainedBytes !== null && combined !== retainedBytes);
  return {
    trash: { count: trash.count, bytes: trash.bytes }, restored: { count: restored.count, bytes: restored.bytes },
    retainedBytes, retainedCount: !overlap && trash.count !== null && restored.count !== null ? trash.count + restored.count : null,
    freeBytes, reserveBytes, aboveReserveBytes: freeBytes !== null && reserveBytes !== null ? Math.max(0, freeBytes - reserveBytes) : null,
    belowReserve: freeBytes !== null && reserveBytes !== null ? freeBytes < reserveBytes : null,
    inconsistent, incomplete: [trash.count, trash.bytes, restored.count, restored.bytes, retainedBytes, freeBytes, reserveBytes].includes(null)
  };
}

export function mountTrash(container, { api, onNotice = () => {}, onLibraryChanged = () => {} } = {}) {
  let status = null;
  let destroyed = false;
  let busy = false;
  let revision = 0;
  let preview = null;
  const selected = new Set();
  const abort = new AbortController();
  container.classList.add('recording-trash');
  container.innerHTML = `<div class="trash-heading"><div><h1>Trash</h1><p class="trash-summary">Loading preserved recordings…</p></div><button type="button" data-action="refresh">Refresh</button></div>
    <div class="trash-policy"><strong>30 days to restore your recordings</strong><p>Deleted clips are preserved here for 30 days. Restore them before they expire, or delete the preserved copies permanently.</p><p>Trash uses additional storage. Original snapshots, car recordings, and archive copies are unchanged.</p></div>
    <section class="trash-storage" aria-labelledby="trash-storage-title"><h2 id="trash-storage-title">Storage</h2><dl class="trash-storage-grid"></dl><p class="trash-storage-warning" role="status" hidden></p>
      <p class="trash-storage-note">Copy sizes include the original camera files and metadata. Total retained includes both Trash and restored copies. These are logical file sizes; disk usage and space reclaimed can differ. Free space is reported by the filesystem holding these copies.</p>
      <p class="trash-restored-help">Restoring keeps the preserved copy in Recordings, with no automatic expiry. To remove it, open Saved or Sentry in Recordings, move the restored clip to Trash again, then delete it permanently here. Empty Trash only removes copies currently in Trash.</p></section>
    <p class="trash-clock" hidden role="status"></p><p class="trash-message" role="status" aria-live="polite"></p>
    <div class="trash-toolbar"><label><input type="checkbox" data-action="select-all"> <span>Select all</span></label><span class="trash-selected"></span><button type="button" data-action="restore" disabled>Restore selected</button><button type="button" data-action="delete" class="trash-danger" disabled>Delete permanently</button><button type="button" data-action="empty" class="trash-danger" disabled>Empty Trash</button></div>
    <div class="trash-items"></div>
    <dialog class="trash-confirm" aria-labelledby="trash-confirm-title"><h2 id="trash-confirm-title">Delete permanently?</h2><p class="trash-confirm-copy"></p><div><button type="button" data-confirm="cancel" autofocus>Keep in Trash</button><button type="button" data-confirm="delete" class="trash-danger">Delete permanently</button></div></dialog>`;
  const find = selector => container.querySelector(selector);
  const message = (value, error = false) => {
    if (destroyed) return;
    find('.trash-message').textContent = value;
    find('.trash-message').classList.toggle('is-error', error);
  };
  const request = api || (async (path, options = {}) => {
    const response = await fetch(path, { credentials: 'same-origin', cache: 'no-store', ...options });
    const value = await response.json();
    if (!response.ok || value.ok === false) throw new Error(value.error || 'The request could not be completed.');
    return value;
  });
  function releasePreview() {
    if (preview) { preview.pause(); preview.removeAttribute('src'); preview.load(); preview = null; }
  }
  function suspend() {
    releasePreview();
    container.querySelectorAll('.trash-preview').forEach(panel => { panel.hidden = true; panel.replaceChildren(); });
  }
  const visibility = () => { if (document.hidden) suspend(); };
  const hiddenObserver = new MutationObserver(() => {
    if (container.hidden || container.getAttribute('aria-hidden') === 'true') suspend();
  });
  hiddenObserver.observe(container, { attributes: true, attributeFilter: ['hidden', 'aria-hidden'] });
  document.addEventListener('visibilitychange', visibility);
  window.addEventListener('pagehide', suspend);
  window.addEventListener('teslausb:pause-media', suspend);
  const trashItems = () => Array.isArray(status?.items) ? status.items.filter(entry => entry && ['id', 'event', 'event_time', 'expires_at'].every(key => typeof entry[key] === 'string')) : [];
  function renderStorage() {
    const storage = trashStorageView(status);
    const grid = find('.trash-storage-grid'); grid.replaceChildren();
    const rows = [
      ['trash', 'In Trash', storage.trash.bytes, recordingCount(storage.trash.count) + ' · 30-day retention'],
      ['restored', 'Restored copies', storage.restored.bytes, recordingCount(storage.restored.count) + ' · kept until removed'],
      ['retained', 'Total retained', storage.retainedBytes, storage.inconsistent ? 'Reported total · details do not match' : recordingCount(storage.retainedCount) + ' · Trash + restored'],
      ['free', 'Free space', storage.freeBytes, 'Available on the copy-storage filesystem'],
      ['reserve', 'Protected reserve', storage.reserveBytes, 'Kept free when making new copies'],
      ['above-reserve', 'Available above reserve', storage.aboveReserveBytes, storage.belowReserve ? 'Free space is below the reserve; new copies may be blocked' : 'Headroom for preserving new copies']
    ];
    for (const [key, label, bytes, detail] of rows) {
      const card = document.createElement('div'); card.dataset.storage = key;
      const term = document.createElement('dt'); term.textContent = label;
      const amount = document.createElement('dd'); amount.textContent = size(bytes);
      const note = document.createElement('p'); note.textContent = detail;
      card.append(term, amount, note); grid.append(card);
    }
    const warning = find('.trash-storage-warning');
    warning.hidden = !status || (!storage.incomplete && !storage.inconsistent);
    warning.textContent = storage.inconsistent ? 'Reported storage totals and copy details are inconsistent. Refresh before relying on these figures.' : 'Some storage details are unavailable. Refresh to check current figures.';
    return storage;
  }
  function selectionControls() {
    const items = trashItems();
    const checkbox = find('[data-action="select-all"]');
    checkbox.checked = !!items.length && selected.size === items.length;
    checkbox.indeterminate = selected.size > 0 && selected.size < items.length;
    checkbox.disabled = busy || !items.length;
    find('.trash-selected').textContent = selected.size ? `${selected.size} selected` : '';
    for (const action of ['restore', 'delete']) find(`[data-action="${action}"]`).disabled = busy || !selected.size;
    find('[data-action="empty"]').disabled = busy || !items.length;
    find('[data-action="refresh"]').disabled = busy;
    container.querySelectorAll('[data-id]').forEach(button => { button.disabled = busy; });
  }
  function render() {
    if (destroyed) return;
    releasePreview();
    const items = trashItems().sort((a, b) => a.expires_at.localeCompare(b.expires_at));
    const storage = renderStorage();
    for (const id of selected) if (!items.some(item => item.id === id)) selected.delete(id);
    find('.trash-summary').textContent = storage.trash.count === null ? 'Trash recording count is unavailable.' : `${recordingCount(storage.trash.count)} in Trash`;
    find('.trash-clock').hidden = status?.clock?.trusted !== false;
    find('.trash-clock').textContent = 'Automatic expiry is paused until the Pi verifies its clock. You can still restore or permanently delete clips.';
    const list = find('.trash-items');
    list.replaceChildren();
    if (!items.length) {
      const empty = document.createElement('p'); empty.className = 'trash-empty';
      empty.textContent = storage.trash.count !== 0 ? 'Trash recordings could not be displayed. Refresh to check the current state.' : storage.restored.count > 0 ? 'Trash is empty. Restored copies still use storage. Move them back to Trash from Recordings to remove their preserved copies.' : 'Trash is empty. Saved and Sentry clips you delete will appear here.';
      list.append(empty);
    }
    for (const entry of items) {
      const card = document.createElement('article'); card.className = 'trash-item';
      const head = document.createElement('div'); head.className = 'trash-item-head';
      const label = document.createElement('label');
      const check = document.createElement('input'); check.type = 'checkbox'; check.checked = selected.has(entry.id);
      check.dataset.id = entry.id; check.dataset.action = 'select';
      check.setAttribute('aria-label', `Select ${entry.event}`);
      const title = document.createElement('strong'); title.textContent = entry.category === 'SentryClips' ? 'Sentry event' : 'Saved drive';
      label.append(check, title);
      const bytes = document.createElement('span'); bytes.textContent = size(entry.bytes);
      head.append(label, bytes);
      const date = document.createElement('p'); date.textContent = entry.event_time.replace('_', ' · ');
      const expiry = document.createElement('p'); expiry.className = 'trash-expiry';
      expiry.textContent = `Scheduled deletion: ${stamp(entry.expires_at)}`;
      const actions = document.createElement('div'); actions.className = 'trash-item-actions';
      for (const [action, text] of [['preview', 'View clip'], ['restore-one', 'Restore'], ['delete-one', 'Delete permanently']]) {
        const button = document.createElement('button'); button.type = 'button';
        button.dataset.id = entry.id; button.dataset.action = action; button.textContent = text;
        if (action === 'delete-one') button.className = 'trash-danger';
        actions.append(button);
      }
      card.append(head, date, expiry, actions);
      const player = document.createElement('div'); player.className = 'trash-preview'; player.hidden = true;
      card.append(player); list.append(card);
    }
    selectionControls();
  }
  async function refresh() {
    if (destroyed || busy) return;
    const requestRevision = ++revision;
    try {
      const response = await request('/api/v1/trash', { signal: abort.signal });
      if (response.ok === false) throw new Error(response.error);
      if (destroyed || requestRevision !== revision) return;
      status = response; render(); message('');
    } catch (error) { if (!destroyed) { if (!status) find('.trash-summary').textContent = 'Trash is unavailable.'; message(error.message || 'Trash is unavailable. Try refreshing.', true); } }
  }
  function confirmDelete(ids) {
    return new Promise(resolve => {
      const dialog = find('.trash-confirm');
      find('.trash-confirm-copy').textContent = `${ids.length} recording${ids.length === 1 ? '' : 's'} and all preserved camera files will be deleted. This cannot be undone. Original snapshots and archive copies are unchanged.`;
      let done = false;
      const finish = value => {
        if (done) return; done = true;
        dialog.removeEventListener('click', click); dialog.removeEventListener('cancel', cancel);
        dialog.close(); resolve(value);
      };
      const click = event => { const button = event.target.closest('[data-confirm]'); if (button) finish(button.dataset.confirm === 'delete'); };
      const cancel = event => { event.preventDefault(); finish(false); };
      dialog.addEventListener('click', click); dialog.addEventListener('cancel', cancel); dialog.showModal();
    });
  }
  async function operate(action, ids) {
    if (busy || !ids.length || destroyed) return;
    if (action === 'delete' && !(await confirmDelete(ids))) return;
    if (destroyed) return;
    revision += 1; busy = true; selectionControls(); releasePreview();
    message(action === 'restore' ? 'Restoring recordings…' : 'Deleting preserved copies…');
    let completed = 0;
    try {
      for (let offset = 0; offset < ids.length; offset += 20) {
        const response = await request('/api/v1/trash/' + action, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-TeslaUSB-Request': '1' }, body: JSON.stringify({ ids: ids.slice(offset, offset + 20) }), signal: abort.signal });
        if (response.ok === false) throw new Error(response.error);
        status = response; completed += Math.min(20, ids.length - offset);
        await onLibraryChanged(status);
      }
      selected.clear(); render();
      const text = action === 'restore' ? `${completed} recording${completed === 1 ? '' : 's'} restored to the library.` : `${completed} preserved recording${completed === 1 ? '' : 's'} permanently deleted.`;
      message(text); onNotice(text);
    } catch (error) {
      message(`${completed ? `${completed} completed. ` : ''}${error.message || 'The operation failed.'} Refresh to check the current state.`, true);
      // A response can be lost after a successful mutation. Never claim rollback.
      try { status = await request('/api/v1/trash', { signal: abort.signal }); render(); await onLibraryChanged(status); } catch { /* Preserve the explicit failure. */ }
    } finally { busy = false; if (!destroyed) selectionControls(); }
  }
  function openPreview(id, button) {
    const entry = trashItems().find(item => item.id === id);
    const files = Array.isArray(entry?.files) ? entry.files.filter(item => item?.camera) : [];
    if (!files.length) return;
    window.dispatchEvent(new CustomEvent('teslausb:pause-media'));
    releasePreview();
    container.querySelectorAll('.trash-preview').forEach(panel => { panel.hidden = true; panel.replaceChildren(); });
    const panel = button.closest('.trash-item').querySelector('.trash-preview'); panel.hidden = false;
    const video = document.createElement('video'); video.controls = true; video.playsInline = true; video.preload = 'metadata';
    video.setAttribute('aria-label', 'Preserved recording preview'); preview = video;
    const controls = document.createElement('div');
    const select = document.createElement('select'); select.setAttribute('aria-label', 'Preserved camera angle');
    files.forEach(file => select.add(new Option(cameraName(file.camera) + ' · ' + file.name.slice(11, 19).replaceAll('-', ':'), file.name)));
    const download = document.createElement('a'); download.textContent = 'Download original camera'; download.className = 'trash-download';
    const downloadAll = document.createElement('a'); downloadAll.textContent = 'Download all cameras · ZIP'; downloadAll.className = 'trash-download';
    downloadAll.href = '/api/v1/trash/download?id=' + encodeURIComponent(entry.id) + '&camera=all';
    const note = document.createElement('p'); note.textContent = 'Preserved original quality. Preview and download use the original camera files.';
    const choose = () => {
      const file = files.find(item => item.name === select.value);
      preview = video;
      video.pause(); video.src = file.media_url;
      download.href = '/api/v1/trash/download?id=' + encodeURIComponent(entry.id) + '&camera=' + encodeURIComponent(file.camera);
    };
    select.addEventListener('change', choose); controls.append(select, download, downloadAll); panel.append(video, controls, note); choose();
  }
  function click(event) {
    const button = event.target.closest('button[data-action]'); if (!button) return;
    const { action, id } = button.dataset;
    if (action === 'refresh') refresh();
    if (action === 'restore') operate('restore', [...selected]);
    if (action === 'delete') operate('delete', [...selected]);
    if (action === 'empty') operate('delete', trashItems().map(item => item.id));
    if (action === 'restore-one') operate('restore', [id]);
    if (action === 'delete-one') operate('delete', [id]);
    if (action === 'preview') openPreview(id, button);
  }
  function change(event) {
    const { action, id } = event.target.dataset;
    if (action === 'select') { event.target.checked ? selected.add(id) : selected.delete(id); selectionControls(); }
    if (action === 'select-all') { selected.clear(); if (event.target.checked) trashItems().forEach(item => selected.add(item.id)); render(); }
  }
  container.addEventListener('click', click); container.addEventListener('change', change);
  renderStorage();
  refresh();
  return { refresh, suspend, destroy() {
    destroyed = true; abort.abort(); releasePreview();
    hiddenObserver.disconnect(); document.removeEventListener('visibilitychange', visibility);
    window.removeEventListener('pagehide', suspend);
    window.removeEventListener('teslausb:pause-media', suspend);
    const dialog = find('.trash-confirm'); if (dialog?.open) dialog.dispatchEvent(new Event('cancel', { cancelable: true }));
    container.removeEventListener('click', click); container.removeEventListener('change', change); container.replaceChildren();
  } };
}
