const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const { setImmediate: settle } = require('node:timers/promises');

// Run the shipped browser script with controlled HTTP responses and timers.
// No browser, dependency installation, app server or host Node is required.
function browser(weatherFetch) {
  const html = readFileSync(`${__dirname}/static/index.html`, 'utf8');
  const nodes = new Map();
  function element() {
    return {
      textContent: '', className: '', dataset: {}, children: [], listeners: {},
      disabled: false,
      addEventListener(name, callback) { this.listeners[name] = callback; },
      setAttribute(name, value) { this[name] = value; },
      querySelector() { return null; },
      prepend(child) { child.parent = this; this.children.unshift(child); },
      remove() { this.parent.children = this.parent.children.filter(child => child !== this); },
      get lastElementChild() { return this.children.at(-1); }
    };
  }
  for (const [, id] of html.matchAll(/\bid="([^"]+)"/g)) nodes.set(`#${id}`, element());
  nodes.set('.weather-card', element());
  const get = selector => {
    assert.ok(nodes.has(selector), `UI selector exists in shipped HTML: ${selector}`);
    return nodes.get(selector);
  };
  get('#version').textContent = 'Connecting…';
  get('#stop-traffic').disabled = true;
  let weatherRequests = 0;
  let id = 0;
  const timers = new Map();
  const events = {};
  vm.runInNewContext(readFileSync(`${__dirname}/static/app.js`, 'utf8'), {
    document: { querySelector: get, createElement: element },
    window: { location: { host: 'localhost:8080' }, addEventListener: (name, fn) => { events[name] = fn; } },
    AbortController, AbortSignal, performance, Date,
    setTimeout: (callback, delay) => { timers.set(++id, { callback, delay }); return id; },
    clearTimeout: key => timers.delete(key),
    fetch: async (url, options) => {
      if (url === '/api/info') return { ok: true, json: async () => ({ version: 'v1' }) };
      assert.equal(url, '/hello-world');
      assert.equal(options.cache, 'no-store');
      weatherRequests += 1;
      return weatherFetch(weatherRequests, options.signal);
    }
  });
  return {
    get, events, timers,
    get weatherRequests() { return weatherRequests; },
    async click(selector) { get(selector).listeners.click(); await settle(); },
    async tick(timeout = false) {
      const entry = [...timers].find(([, timer]) => timeout ? timer.delay === 2000 : timer.delay <= 100);
      assert.ok(entry, timeout ? 'request timeout exists' : 'next request is scheduled');
      timers.delete(entry[0]);
      entry[1].callback();
      await settle();
    }
  };
}

function forecast(requestNumber, status = 200, version = 'v1') {
  return {
    ok: status === 200, status, statusText: status === 200 ? 'OK' : 'Internal Server Error',
    json: async () => ({
      version, requestNumber, temperatureC: status === 200 ? 3 : 30,
      condition: status === 200 ? 'Cloudy' : 'Sunny', message: 'Simulated forecast'
    })
  };
}

test('traffic is opt-in; HTTP 500 does not stop it; history is bounded and errors remain visible', async () => {
  const ui = browser(n => forecast(n, n === 2 ? 500 : 200, n === 2 ? 'v2' : 'v1'));
  await settle();
  assert.equal(ui.weatherRequests, 0);
  assert.equal(ui.timers.size, 0);
  await ui.click('#start-traffic');
  await ui.click('#start-traffic'); // Duplicate Start must not create a second loop.
  assert.equal(ui.weatherRequests, 1);
  await ui.click('#refresh'); // Manual requests are disabled during automatic traffic.
  assert.equal(ui.weatherRequests, 1);
  for (let n = 0; n < 19; n += 1) await ui.tick();
  assert.equal(ui.weatherRequests, 20);
  assert.equal(ui.get('#count-v1').textContent, '19');
  assert.equal(ui.get('#count-v2').textContent, '1');
  assert.equal(ui.get('#count-500').textContent, '1');
  assert.equal(ui.get('#count-other').textContent, '0');
  assert.equal(ui.get('#history').children.length, 12);
  assert.match(ui.get('#last-failure').textContent, /v2 · 500/);
  assert.equal(ui.get('#version').textContent, 'v1');
  await ui.click('#stop-traffic');
  assert.equal(ui.timers.size, 0);
  assert.equal(ui.get('#traffic-status').textContent, 'Stopped');
  await ui.click('#start-traffic');
  assert.equal(ui.weatherRequests, 21);
  await ui.click('#stop-traffic');
  await ui.click('#refresh');
  assert.equal(ui.weatherRequests, 22);
  assert.equal(ui.timers.size, 0);
});

test('Stop aborts an in-flight request without recording a failure and allows restart', async () => {
  let signal;
  const ui = browser((n, requestSignal) => {
    if (n > 1) return forecast(n);
    signal = requestSignal;
    return new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('Aborted'))));
  });
  await ui.click('#start-traffic');
  await ui.click('#start-traffic');
  assert.equal(ui.weatherRequests, 1);
  assert.equal(ui.get('#start-traffic').disabled, true);
  await ui.click('#stop-traffic');
  assert.equal(signal.aborted, true);
  assert.equal(ui.get('#history').children.length, 0);
  assert.equal(ui.timers.size, 0);
  assert.equal(ui.get('#start-traffic').disabled, false);
  await ui.click('#start-traffic');
  assert.equal(ui.weatherRequests, 2);
  ui.events.pagehide();
  assert.equal(ui.timers.size, 0);
});

test('timeouts are separate from HTTP 500 and traffic recovers without overlapping requests', async () => {
  const ui = browser((n, signal) => n === 1
    ? new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('Timeout'))))
    : forecast(n));
  await ui.click('#start-traffic');
  assert.equal(ui.timers.size, 1); // Only timeout: no next request until completion.
  await ui.tick(true);
  assert.equal(ui.get('#count-500').textContent, '0');
  assert.equal(ui.get('#count-other').textContent, '1');
  await ui.tick();
  assert.equal(ui.weatherRequests, 2);
  assert.equal(ui.get('#count-v1').textContent, '1');
  await ui.click('#stop-traffic');
});

test('Stop while reading a response body discards late results', async () => {
  let finishBody;
  const ui = browser(n => ({ ...forecast(n), json: () => new Promise(resolve => { finishBody = resolve; }) }));
  await ui.click('#start-traffic');
  await ui.click('#stop-traffic');
  finishBody(await forecast(1, 500, 'v2').json());
  await settle();
  assert.equal(ui.get('#history').children.length, 0);
  assert.equal(ui.timers.size, 0);
  assert.equal(ui.get('#start-traffic').disabled, false);
});
