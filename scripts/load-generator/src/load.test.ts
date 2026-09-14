import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

test('continues after HTTP 500 and broken connections, then stops on SIGTERM', { timeout: 15000 }, async () => {
  let calls = 0;
  let wrongPaths = 0;
  const server = createServer((request, response) => {
    if (request.url !== '/hello-world') wrongPaths += 1;
    calls += 1;
    // A block of broken connections also defeats a client's transparent retry.
    if (calls >= 7 && calls <= 12) {
      request.socket.destroy();
      return;
    }
    response.writeHead(calls % 2 === 0 ? 500 : 200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ version: 'fixture' }));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  const child = spawn(process.execPath, [fileURLToPath(new URL('./load.js', import.meta.url))], {
    env: {
      ...process.env,
      TARGET_URL: `http://127.0.0.1:${address.port}/hello-world`,
      REQUEST_INTERVAL_MS: '20', REPORT_INTERVAL_MS: '200', REQUEST_TIMEOUT_MS: '500',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  let errors = '';
  child.stdout.on('data', (chunk: Buffer) => { output += chunk.toString(); });
  child.stderr.on('data', (chunk: Buffer) => { errors += chunk.toString(); });
  const closed = once(child, 'close');
  const deadline = setTimeout(() => { child.kill('SIGKILL'); }, 10000);
  try {
    // Wait for observable progress, not a fixed number of calls during startup.
    const until = Date.now() + 8000;
    while (calls < 18 && child.exitCode === null && Date.now() < until) await sleep(25);
    assert.ok(calls >= 18, `Traffic did not continue: ${output}\n${errors}`);
    child.kill('SIGTERM');
    const [code, signal] = await closed;
    assert.equal(code, 0, errors);
    assert.equal(signal, null);
    assert.equal(wrongPaths, 0);
    assert.match(output, /statuses=.*200:/);
    assert.match(output, /statuses=.*500:/);
    assert.match(output, /total_success=[1-9]\d*/);
    assert.match(output, /total_http_errors=[1-9]\d*/);
    assert.match(output, /total_connection_errors=[1-9]\d*/);
    assert.match(output, /Traffic generator stopped\./);
  } finally {
    clearTimeout(deadline);
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    await closed;
    server.closeAllConnections();
    await new Promise<void>((resolve) => { server.close(() => resolve()); });
  }
});
