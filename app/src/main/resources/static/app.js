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
let succeeded = 0;
let failed = 0;

function remember(label, isError) {
  history.querySelector('.history-empty')?.remove();
  const item = document.createElement('li');
  item.textContent = label;
  item.className = isError ? 'error' : '';
  history.prepend(item);
  while (history.children.length > 6) history.lastElementChild.remove();
  if (isError) failed += 1;
  else succeeded += 1;
  totals.textContent = `${succeeded} successful · ${failed} failed`;
}

button.addEventListener('click', async () => {
  button.disabled = true;
  button.textContent = 'Checking Stockholm…';
  let response;
  try {
    response = await fetch('/hello-world', {
      cache: 'no-store', signal: AbortSignal.timeout(10000)
    });
    // fetch resolves for HTTP 500 too: read its JSON and show the sunny joke.
    const weather = await response.json();
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
    remember(`${weather.version} · ${response.status}`, isError);
  } catch (error) {
    card.dataset.weather = 'offline';
    temperature.textContent = '—';
    condition.textContent = response ? 'Unexpected response' : 'Weather station unreachable';
    message.textContent = response
      ? 'The server did not return the expected weather data. You can try again.'
      : 'The app may be starting or switching versions. Give it a moment and try again.';
    badge.className = 'response-badge error';
    badge.textContent = response ? `HTTP ${response.status} · unreadable forecast` : 'Connection error';
    detail.textContent = 'This is different from the simulated sunny HTTP 500.';
    remember(response ? `${response.status} · invalid data` : 'Connection error', true);
  } finally {
    button.disabled = false;
    button.textContent = 'Refresh weather ↗';
  }
});

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
