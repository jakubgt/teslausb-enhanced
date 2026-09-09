// Browser-to-server contact only. USB, recording, and application health are
// separate states. The caller supplies transport evidence and owns all polling.
export function mountConnectionBanner(container, { retry = async () => {}, isPaused = () => false } = {}) {
  const document = container.ownerDocument;
  const view = document.defaultView;
  const issued = new WeakSet();
  let alive = true;
  let serial = 0;
  let contactCutoff = 0;
  let contactVersion = 0;
  let lastContact = null;
  let lost = view.navigator?.onLine === false;
  let offline = lost;
  let paused = Boolean(isPaused());
  let retrying = false;
  let retryNote = '';

  const element = (tag, className) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    return node;
  };
  const dot = element('span', 'connection-dot'); dot.setAttribute('aria-hidden', 'true');
  const body = element('div', 'connection-copy');
  const live = element('div', 'connection-live');
  live.setAttribute('role', 'status'); live.setAttribute('aria-live', 'polite'); live.setAttribute('aria-atomic', 'true');
  const title = element('strong', 'connection-title');
  const detail = element('span', 'connection-detail');
  const contact = element('p', 'connection-contact');
  const button = element('button', 'connection-retry');
  button.type = 'button'; button.setAttribute('aria-label', 'Retry connection');
  live.append(title, detail); body.append(live, contact);
  container.classList.add('connection-banner');
  container.setAttribute('role', 'region'); container.setAttribute('aria-label', 'Connection to TeslaUSB');
  container.replaceChildren(dot, body, button);

  function text(node, value) { if (node.textContent !== value) node.textContent = value; }
  function render() {
    if (!alive) return;
    let state;
    let label;
    let explanation;
    if (retrying) {
      state = 'connecting'; label = 'Connecting';
      explanation = paused ? 'Checking TeslaUSB. Automatic checks are paused.' : 'Checking whether TeslaUSB is reachable…';
    } else if (paused) {
      state = 'paused'; label = 'Connection checks paused';
      explanation = 'A power action is pending. Retry checks whether TeslaUSB is back.';
    } else if (lost) {
      state = 'lost'; label = 'Connection lost';
      explanation = offline ? 'Your browser reports no network connection.' : 'TeslaUSB is not responding. Check power and Wi-Fi, then retry.';
    } else if (lastContact !== null) {
      state = 'connected'; label = 'Connected'; explanation = 'This browser can reach TeslaUSB.';
    } else {
      state = 'connecting'; label = 'Connecting'; explanation = 'Waiting for a response from TeslaUSB.';
    }
    container.dataset.state = state;
    text(title, label);
    text(detail, retryNote && !retrying && state !== 'connected' && state !== 'paused' ? retryNote : explanation);
    // Keep timestamps outside the live region: concurrent API responses should
    // not repeatedly interrupt screen-reader users with contact-time updates.
    text(contact, lastContact === null ? 'No server response yet.' : `Last successful contact: ${new Date(lastContact).toLocaleString()}`);
    if (lastContact === null) contact.removeAttribute('data-contact-at');
    else contact.setAttribute('data-contact-at', new Date(lastContact).toISOString());
    button.hidden = state === 'connected' && !retrying;
    button.disabled = retrying;
    button.setAttribute('aria-busy', String(retrying));
    text(button, retrying ? 'Checking…' : 'Retry');
  }

  function consume(token) {
    if (!alive || token === null || typeof token !== 'object' || !issued.has(token)) return false;
    issued.delete(token);
    return true;
  }
  function beginRequest() {
    if (!alive) return null;
    const token = Object.freeze({ sequence: ++serial });
    issued.add(token);
    return token;
  }
  function receivedResponse(token) {
    if (!consume(token)) return;
    // All requests already in progress predate this fresh contact, regardless
    // of which concurrent request supplied the response. Their later timeouts
    // are not evidence that contact has since been lost.
    contactCutoff = serial;
    contactVersion += 1;
    lastContact = Date.now();
    lost = false; offline = false; retryNote = '';
    paused = Boolean(isPaused());
    render();
  }
  function requestFailed(token) {
    if (!consume(token) || token.sequence <= contactCutoff) return;
    lost = true; retryNote = '';
    paused = Boolean(isPaused());
    render();
  }
  function setPaused() {
    if (!alive) return;
    paused = Boolean(isPaused());
    retryNote = '';
    render();
  }
  async function tryAgain() {
    if (!alive || retrying) return;
    retrying = true; retryNote = '';
    paused = Boolean(isPaused());
    const before = contactVersion;
    render();
    try {
      await retry();
      // Promise resolution alone can be a local no-op. Only an instrumented
      // HTTP response confirms contact; retry never replays the failed action.
      if (alive && before === contactVersion) retryNote = 'No new server response was observed. Retry to check again.';
    } catch {
      // An HTTP/application error or user abort is not a transport failure.
      // requestFailed() is the sole API-failure signal supplied by the caller.
      if (alive && before === contactVersion && !lost) retryNote = 'The connection check did not complete. Retry to check again.';
    } finally {
      if (alive) {
        retrying = false;
        paused = Boolean(isPaused());
        render();
      }
    }
  }
  function browserOffline() {
    if (!alive) return;
    offline = true; lost = true; retryNote = '';
    paused = Boolean(isPaused());
    render();
  }
  function browserOnline() {
    if (!alive) return;
    offline = false;
    // An online event says only that the browser has a network interface.
    // It neither proves a TeslaUSB response nor starts another request.
    retryNote = lost ? 'The browser network is available. Retry to check TeslaUSB.' : '';
    paused = Boolean(isPaused());
    render();
  }
  button.addEventListener('click', tryAgain);
  view.addEventListener('offline', browserOffline);
  view.addEventListener('online', browserOnline);
  render();
  return { beginRequest, receivedResponse, requestFailed, setPaused, destroy() {
    if (!alive) return;
    alive = false;
    button.removeEventListener('click', tryAgain);
    view.removeEventListener('offline', browserOffline);
    view.removeEventListener('online', browserOnline);
    container.replaceChildren(); container.classList.remove('connection-banner');
    container.removeAttribute('role'); container.removeAttribute('aria-label');
    delete container.dataset.state;
  } };
}
