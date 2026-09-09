/* Retain the established file manager's encoding, mutation confirmation, folder
 * upload, drag/drop, rename, and lock-sound behavior in the modern shell. */
export function configuredFileDrives(config) {
  return [['music', 'Music'], ['lightshow', 'LightShow'], ['boombox', 'Boombox']]
    .filter(([key]) => config?.[`has_${key}`] === 'yes')
    .map(([, label]) => ({path: `fs/${label}`, label}));
}

let legacyReady;
function loadStyle(path) {
  if (document.querySelector(`link[data-files-style="${path}"]`)) return;
  const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = path;
  link.dataset.filesStyle = path; document.head.append(link);
}
function loadScript(path) {
  return new Promise((resolve, reject) => {
    const script = document.createElement('script'); script.src = path;
    script.onload = resolve;
    script.onerror = () => { script.remove(); reject(new Error(`Could not load ${path}. Refresh to retry.`)); };
    document.head.append(script);
  });
}
async function legacyBrowser() {
  if (!legacyReady) legacyReady = (async () => {
    loadStyle('/contextmenu.css'); loadStyle('/filebrowser.css');
    if (typeof ContextMenu === 'undefined') await loadScript('/contextmenu.js');
    if (typeof FileBrowser === 'undefined') await loadScript('/filebrowser.js');
    return FileBrowser;
  })().catch(error => { legacyReady = null; throw error; });
  return legacyReady;
}

export function mountFiles(container, {api, onNotice = () => {}, config}) {
  let destroyed = false, browser = null, loading = null;
  const root = document.createElement('div'); root.className = 'files-root';
  root.innerHTML = `<div class="files-heading"><div><p class="device-eyebrow">YOUR VIRTUAL DRIVES</p><h1>Files</h1><p>Music, LightShow, and Boombox files ready for your vehicle.</p></div><button type="button" data-files="refresh">Refresh files</button></div><p class="files-help">Select an item for rename, download, or delete. Open a folder or audio file with a double click or Enter. You can also drag files and folders here to upload.</p><p class="files-status" data-files="status" role="status" aria-live="polite">Loading configured drives…</p><div class="files-browser" data-files="browser"></div>`;
  container.replaceChildren(root);
  const find = key => root.querySelector(`[data-files="${key}"]`);
  const refreshButton = find('refresh');
  function stopAudio() {
    root.querySelectorAll('audio').forEach(audio => { audio.pause(); audio.removeAttribute('src'); audio.load(); });
    root.querySelectorAll('.files-audio-dialog').forEach(dialog => { dialog.close(); dialog.remove(); });
  }
  const onVisibility = () => { if (document.hidden) stopAudio(); };
  window.addEventListener('teslausb:pause-media', stopAudio);
  document.addEventListener('visibilitychange', onVisibility);
  window.addEventListener('pagehide', stopAudio);

  async function initialize() {
    const currentConfig = config || await api('/api/v1/config');
    if (destroyed) return;
    const drives = configuredFileDrives(currentConfig);
    if (!drives.length) {
      find('status').textContent = 'No Music, LightShow, or Boombox drive is configured on this device.';
      find('browser').hidden = true; refreshButton.hidden = true; return;
    }
    const BaseBrowser = await legacyBrowser();
    if (destroyed) return;
    class ManagedBrowser extends BaseBrowser {
      track(request) { (this.requests ||= new Set()).add(request); request.addEventListener('loadend', () => this.requests.delete(request), {once: true}); return request; }

      // All requests are owned by this view and aborted when it is unmounted.
      readfile({url, callback, callbackarg, method = 'GET', headers = {}}) {
        if (this.disposed) return;
        const request = this.track(new XMLHttpRequest()); let completed = false;
        const finish = (body, error) => { if (completed) return; completed = true; if (!this.disposed) callback?.(body, callbackarg, error); };
        request.open(method, url); request.timeout = 30000;
        for (const [name, value] of Object.entries(headers)) request.setRequestHeader(name, value);
        request.onload = () => request.status >= 200 && request.status < 300
          ? finish(request.responseText, null)
          : finish(request.responseText || null, {status: request.status, statusText: request.statusText || 'Request failed', responseText: request.responseText || ''});
        request.onerror = () => finish(null, {status: request.status, statusText: 'Network error'});
        request.onabort = () => finish(null, {status: request.status, statusText: 'Request cancelled'});
        request.ontimeout = () => finish(null, {status: request.status, statusText: 'Request timed out'});
        request.send();
      }

      async uploadFile(destpath, entry, completionCallback, progressCallback) {
        const file = await this.getFilePromise(entry);
        if (this.disposed || this.cancelUpload) { this.uploading = false; return; }
        const relpath = entry instanceof File ? file.name : entry.fullPath.slice(1);
        const request = this.track(new XMLHttpRequest()); this.currentUpload = request; let completed = false;
        const finish = (status, message) => {
          if (completed) return; completed = true;
          if (this.currentUpload === request) this.currentUpload = null;
          if (!this.disposed) completionCallback(status, message || request.statusText || 'Request failed');
        };
        request.open('POST', `/api/v1/files/upload?${encodeURIComponent(`${this.root_path}/${destpath}`)}&${encodeURIComponent(relpath)}`);
        request.setRequestHeader('Content-Type', 'application/octet-stream');
        request.setRequestHeader('X-TeslaUSB-Request', '1'); request.timeout = 300000;
        request.onload = () => finish(request.status, request.statusText);
        request.onerror = () => finish(request.status, 'Network error');
        request.onabort = () => finish(0, 'Upload cancelled');
        request.ontimeout = () => finish(0, 'Upload timed out');
        request.upload.onprogress = event => { if (!this.disposed) progressCallback(event, request); };
        request.send(file);
      }

      async cancelDrop() {
        this.cancelUpload = true; this.currentUpload?.abort(); this.uploading = false;
        if (!this.disposed) { this.hideDropInfo(); this.showOperationStatus('Upload cancelled.'); }
      }

      showOperationError(action, error, response) {
        if (!this.disposed) super.showOperationError(action, error, response);
      }

      fileClicked(event, path) {
        if (!this.isPlayable(path)) return;
        window.dispatchEvent(new CustomEvent('teslausb:pause-media'));
        const dialog = document.createElement('dialog'); dialog.className = 'files-audio-dialog';
        const title = document.createElement('h2'); title.textContent = path;
        const close = document.createElement('button'); close.type = 'button'; close.textContent = 'Close player';
        const audio = document.createElement('audio'); audio.controls = true;
        audio.src = '/' + `${this.root_path}/${path}`.split('/').map(encodeURIComponent).join('/');
        audio.addEventListener('error', () => this.showOperationStatus(`Could not play ${path}. The file may be unsupported or unavailable.`, true));
        close.addEventListener('click', () => dialog.close());
        dialog.addEventListener('close', () => { audio.pause(); audio.removeAttribute('src'); audio.load(); dialog.remove(); });
        dialog.append(title, audio, close); root.append(dialog); dialog.showModal();
        audio.play().catch(() => { this.showOperationStatus('Press Play to listen to this file.'); });
      }

      downloadSelection() {
        this.showOperationStatus(this.numSelected() > 1 ? 'Preparing a ZIP download. Your browser will show the transfer; cancel it in Downloads if needed.' : 'Download requested. Your browser will show transfer progress.');
        super.downloadSelection();
      }

      dispose() {
        this.disposed = true; this.cancelUpload = true; this.uploading = false;
        this.requests?.forEach(request => request.abort()); this.requests?.clear();
        this.anchor_elem.querySelectorAll('[contenteditable="true"]').forEach(item => { item.onblur = null; item.contentEditable = false; });
      }
    }
    browser = new ManagedBrowser(find('browser'), drives);
    // Existing toolbar actions already have explicit accessible labels. Visible
    // labels make them equally discoverable without hovering over icons.
    for (const [selector, label] of [['pencil', 'Rename'], ['locksound', 'Use as lock sound'], ['newfolder', 'New folder'], ['download', 'Download'], ['upload', 'Upload'], ['trash', 'Delete']]) {
      browser.buttonbar.querySelector(`.fb-${selector}button`).textContent = label;
    }
    find('status').classList.remove('files-error');
    find('status').textContent = `Available drives: ${drives.map(drive => drive.label).join(', ')}. File deletion is permanent; the recording Trash applies to Sentry and Saved clips.`;
    browser.anchor_elem.querySelector('.fb-driveselector')?.addEventListener('change', stopAudio);
  }
  async function refresh() {
    if (destroyed || loading) return loading;
    refreshButton.disabled = true;
    loading = (browser ? browser.refreshLists() : initialize()).catch(error => {
      if (destroyed) return;
      find('status').textContent = `Files unavailable: ${error.message}`; find('status').classList.add('files-error'); onNotice(`Files unavailable: ${error.message}`);
    }).finally(() => { loading = null; if (!destroyed) refreshButton.disabled = false; });
    return loading;
  }
  refreshButton.addEventListener('click', () => void refresh());
  void refresh();
  return {refresh, suspend: stopAudio, destroy() { destroyed = true; window.removeEventListener('teslausb:pause-media', stopAudio); document.removeEventListener('visibilitychange', onVisibility); window.removeEventListener('pagehide', stopAudio); stopAudio(); browser?.dispose(); root.remove(); }};
}
