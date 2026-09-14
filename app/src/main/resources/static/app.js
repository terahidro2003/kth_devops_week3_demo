const button = document.querySelector('#refresh');
const card = document.querySelector('.weather-card');
const version = document.querySelector('#version');
const temperature = document.querySelector('#temperature');
const condition = document.querySelector('#condition');
const message = document.querySelector('#message');
const badge = document.querySelector('#response');
const detail = document.querySelector('#request-detail');
const history = document.querySelector('#history');
const totals = document.querySelector('#totals');
const startButton = document.querySelector('#start-traffic');
const stopButton = document.querySelector('#stop-traffic');
const trafficStatus = document.querySelector('#traffic-status');
const lastFailure = document.querySelector('#last-failure');
const counts = { v1: 0, v2: 0, http500: 0, other: 0 };
const REQUEST_INTERVAL_MS = 100;
const REQUEST_TIMEOUT_MS = 2000;
let running = false;
let nextRequestTimer;
let activeRequest;
let succeeded = 0;
let failed = 0;

document.querySelector('#traffic-target').textContent = window.location.host;

function updateControls() {
  button.disabled = running || Boolean(activeRequest);
  button.textContent = running ? 'Automatic traffic active'
    : activeRequest ? 'Checking Stockholm…' : 'Refresh weather ↗';
  startButton.disabled = running || Boolean(activeRequest);
  stopButton.disabled = !running;
  trafficStatus.textContent = running ? 'Running · up to 10 requests/s' : 'Stopped';
  trafficStatus.dataset.running = String(running);
  // Avoid announcing every forecast at 10 Hz to assistive technology.
  document.querySelector('#forecast').setAttribute('aria-live', running ? 'off' : 'polite');
}

function remember(label, isError, responseVersion, status) {
  history.querySelector('.history-empty')?.remove();
  const item = document.createElement('li');
  item.textContent = label;
  item.className = isError ? 'error' : '';
  history.prepend(item);
  while (history.children.length > 12) history.lastElementChild.remove();
  if (isError) failed += 1;
  else succeeded += 1;
  totals.textContent = `${succeeded} successful · ${failed} failed`;
  if (responseVersion === 'v1' || responseVersion === 'v2') counts[responseVersion] += 1;
  if (status === 500) counts.http500 += 1;
  else if (isError) counts.other += 1;
  document.querySelector('#count-v1').textContent = String(counts.v1);
  document.querySelector('#count-v2').textContent = String(counts.v2);
  document.querySelector('#count-500').textContent = String(counts.http500);
  document.querySelector('#count-other').textContent = String(counts.other);
  if (isError) {
    lastFailure.className = 'last-failure error';
    lastFailure.textContent = `Last failure · ${new Date().toLocaleTimeString('en-GB')} · ${label}${status === 500 && responseVersion ? ' · Sunny & warm, 30 °C' : ''}`;
  }
}

async function requestWeather() {
  if (activeRequest) return;
  const request = { controller: new AbortController(), cancelled: false };
  activeRequest = request;
  updateControls();
  const timeout = setTimeout(() => request.controller.abort(), REQUEST_TIMEOUT_MS);
  let response;
  try {
    response = await fetch('/hello-world', {
      cache: 'no-store', signal: request.controller.signal
    });
    // fetch resolves for HTTP 500 too: read its JSON and show the sunny joke.
    const weather = await response.json();
    if (request.cancelled) return;
    if (typeof weather.temperatureC !== 'number' || typeof weather.version !== 'string'
        || typeof weather.condition !== 'string' || typeof weather.message !== 'string') {
      throw new Error('Unexpected weather response');
    }
    const isError = !response.ok;
    card.dataset.weather = isError ? 'sunny' : 'cloudy';
    version.textContent = weather.version;
    temperature.textContent = String(weather.temperatureC);
    condition.textContent = `${weather.condition} & ${isError ? 'warm' : 'cold'}`;
    message.textContent = weather.message;
    badge.className = `response-badge ${isError ? 'error' : 'ok'}`;
    badge.textContent = `${response.status} ${response.status === 500 ? 'Internal Server Error' : response.statusText}`;
    detail.textContent = `Server request #${weather.requestNumber} · ${new Date().toLocaleTimeString('en-GB')}`;
    remember(`${weather.version} · ${response.status}`, isError, weather.version, response.status);
  } catch (error) {
    // Stop is a user action, not an application failure or an HTTP 500.
    if (request.cancelled) return;
    card.dataset.weather = 'offline';
    temperature.textContent = '—';
    condition.textContent = response ? 'Unexpected response' : 'Weather station unreachable';
    message.textContent = response
      ? 'The server did not return the expected weather data. You can try again.'
      : 'The app may be starting or switching versions. Give it a moment and try again.';
    badge.className = 'response-badge error';
    badge.textContent = response ? `HTTP ${response.status} · unreadable forecast` : 'Connection error';
    detail.textContent = 'This is different from the simulated sunny HTTP 500.';
    remember(response ? `${response.status} · invalid data` : 'Connection error / timeout', true, null, response?.status);
  } finally {
    clearTimeout(timeout);
    activeRequest = undefined;
    updateControls();
  }
}

async function generateTraffic() {
  if (!running) return;
  const startedAt = performance.now();
  await requestWeather();
  if (running) {
    // Schedule after completion: slow requests never create an accumulating queue.
    nextRequestTimer = setTimeout(generateTraffic,
      Math.max(0, REQUEST_INTERVAL_MS - (performance.now() - startedAt)));
  }
}

function stopTraffic() {
  running = false;
  clearTimeout(nextRequestTimer);
  if (activeRequest) {
    activeRequest.cancelled = true;
    activeRequest.controller.abort();
  }
  updateControls();
}

button.addEventListener('click', () => {
  if (!running) void requestWeather();
});
startButton.addEventListener('click', () => {
  if (running || activeRequest) return;
  running = true;
  updateControls();
  void generateTraffic();
});
stopButton.addEventListener('click', stopTraffic);
window.addEventListener('pagehide', stopTraffic);

async function loadInfo() {
  try {
    const response = await fetch('/api/info', {
      cache: 'no-store', signal: AbortSignal.timeout(10000)
    });
    if (!response.ok) throw new Error('Info unavailable');
    const info = await response.json();
    // An info request must not overwrite a version already shown by a forecast.
    if (version.textContent === 'Connecting…') version.textContent = info.version;
  } catch {
    if (version.textContent === 'Connecting…') version.textContent = 'Version pending';
  }
}
loadInfo();
