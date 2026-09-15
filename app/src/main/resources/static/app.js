const refreshButton = document.querySelector('#refresh');
const loadToggle = document.querySelector('#load-toggle');
const loadHint = document.querySelector('#load-hint');
const card = document.querySelector('.status-card');
const version = document.querySelector('#version');
const httpStatus = document.querySelector('#http-status');
const latency = document.querySelector('#latency');
const outcome = document.querySelector('#outcome');
const requestNumber = document.querySelector('#request-number');
const badge = document.querySelector('#response');
const detail = document.querySelector('#request-detail');
const history = document.querySelector('#history');
const totals = document.querySelector('#totals');

let succeeded = 0;
let failed = 0;
let loadTimer = null;
let inFlight = false;
const LOAD_INTERVAL_MS = 100;

function remember(label, kind) {
  history.querySelector('.history-empty')?.remove();
  const item = document.createElement('li');
  item.textContent = label;
  item.className = kind === 'ok' ? '' : kind;
  history.prepend(item);
  while (history.children.length > 6) history.lastElementChild.remove();
  if (kind === 'error') failed += 1;
  else succeeded += 1;
  totals.textContent = `${succeeded} ok · ${failed} failed`;
}

function applyResponse(response, body, clientMs) {
  const isError = !response.ok;
  const isSlow = !isError && typeof body.latencyMs === 'number' && body.latencyMs >= 500;
  const kind = isError ? 'error' : isSlow ? 'slow' : 'ok';

  card.dataset.state = kind;
  version.textContent = body.version;
  httpStatus.textContent = String(response.status);
  latency.textContent = `${body.latencyMs} ms`;
  outcome.textContent = body.outcome;
  requestNumber.textContent = String(body.requestNumber);
  badge.className = `response-badge ${kind}`;
  badge.textContent = `${response.status} ${response.statusText || ''}`.trim();
  detail.textContent = `Server #${body.requestNumber} · client ${clientMs} ms · ${new Date().toLocaleTimeString('en-GB')}`;
  remember(`${body.version} · ${response.status} · ${body.latencyMs} ms`, kind);
}

function applyError(response, message) {
  card.dataset.state = 'error';
  httpStatus.textContent = response ? String(response.status) : '—';
  latency.textContent = '—';
  outcome.textContent = 'error';
  requestNumber.textContent = '—';
  badge.className = 'response-badge error';
  badge.textContent = response ? `HTTP ${response.status}` : 'Connection error';
  detail.textContent = message;
  remember(response ? `${response.status} · invalid data` : 'Connection error', 'error');
}

async function sendHello() {
  if (inFlight) return;
  inFlight = true;
  refreshButton.disabled = true;
  const started = performance.now();
  let response;
  try {
    response = await fetch('/hello-world', {
      cache: 'no-store',
      signal: AbortSignal.timeout(10000)
    });
    const body = await response.json();
    if (typeof body.version !== 'string'
        || typeof body.requestNumber !== 'number'
        || typeof body.latencyMs !== 'number'
        || typeof body.outcome !== 'string') {
      throw new Error('Unexpected response shape');
    }
    applyResponse(response, body, Math.round(performance.now() - started));
  } catch {
    applyError(
      response,
      response
        ? 'The server did not return the expected demo payload.'
        : 'The app may be starting or switching versions. Try again shortly.'
    );
  } finally {
    inFlight = false;
    refreshButton.disabled = loadTimer !== null;
  }
}

function setLoadRunning(running) {
  if (running) {
    loadToggle.setAttribute('aria-pressed', 'true');
    loadToggle.textContent = 'Stop load';
    loadHint.textContent = 'Load running — continuous /hello-world requests.';
    refreshButton.disabled = true;
    if (loadTimer === null) {
      sendHello();
      loadTimer = setInterval(sendHello, LOAD_INTERVAL_MS);
    }
  } else {
    if (loadTimer !== null) {
      clearInterval(loadTimer);
      loadTimer = null;
    }
    loadToggle.setAttribute('aria-pressed', 'false');
    loadToggle.textContent = 'Start load';
    loadHint.textContent = 'Load sends continuous requests to /hello-world (~10/s).';
    refreshButton.disabled = inFlight;
  }
}

refreshButton.addEventListener('click', () => {
  sendHello();
});

loadToggle.addEventListener('click', () => {
  setLoadRunning(loadTimer === null);
});

async function loadInfo() {
  try {
    const response = await fetch('/api/info', {
      cache: 'no-store',
      signal: AbortSignal.timeout(10000)
    });
    if (!response.ok) throw new Error('Info unavailable');
    const info = await response.json();
    if (version.textContent === 'Connecting…') {
      version.textContent = info.version;
      detail.textContent = `Configured latency ${info.latencyMs} ms`;
    }
  } catch {
    if (version.textContent === 'Connecting…') version.textContent = 'Version pending';
  }
}

loadInfo();
