import { setTimeout as sleep } from 'node:timers/promises';

function integerSetting(name: string, fallback: number, min: number, max: number): number {
  const raw = process.env[name] ?? String(fallback);
  const value = Number(raw);
  if (!/^\d+$/.test(raw) || !Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

const target = new URL(process.env.TARGET_URL ?? 'http://app:8080/hello-world');
if (!['http:', 'https:'].includes(target.protocol)) {
  throw new Error('TARGET_URL must use http or https.');
}
const intervalMs = integerSetting('REQUEST_INTERVAL_MS', 100, 10, 60000);
const timeoutMs = integerSetting('REQUEST_TIMEOUT_MS', 5000, 100, 60000);
const reportMs = integerSetting('REPORT_INTERVAL_MS', 5000, 100, 60000);

const shutdown = new AbortController();
for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => shutdown.abort());
}

type Counts = {
  success: number;
  httpErrors: number;
  connectionErrors: number;
  statuses: Map<number, number>;
};
function emptyCounts(): Counts {
  return { success: 0, httpErrors: 0, connectionErrors: 0, statuses: new Map() };
}
const total = emptyCounts();
let recent = emptyCounts();
let reportStartedAt = performance.now();
let completedTotal = 0;

function record(status?: number): void {
  for (const counts of [total, recent]) {
    if (status === undefined) counts.connectionErrors += 1;
    else {
      if (status >= 200 && status < 300) counts.success += 1;
      else counts.httpErrors += 1;
      counts.statuses.set(status, (counts.statuses.get(status) ?? 0) + 1);
    }
  }
  completedTotal += 1;
}

function report(): void {
  const now = performance.now();
  const seconds = Math.max((now - reportStartedAt) / 1000, 0.001);
  const completed = recent.success + recent.httpErrors + recent.connectionErrors;
  const responses = recent.success + recent.httpErrors;
  const percentage = responses === 0 ? 'n/a' : `${(100 * recent.httpErrors / responses).toFixed(1)}%`;
  const statuses = [...recent.statuses].sort(([a], [b]) => a - b)
    .map(([status, count]) => `${status}:${count}`).join(',') || 'none';
  console.log(
    `window_s=${seconds.toFixed(1)} completed=${completed} success=${recent.success} ` +
    `http_errors=${recent.httpErrors} connection_errors=${recent.connectionErrors} ` +
    `rps=${(completed / seconds).toFixed(1)} http_error_pct=${percentage} statuses=${statuses}`,
  );
  recent = emptyCounts();
  reportStartedAt = now;
}

console.log(`Sending GET ${target.href} approximately every ${intervalMs} ms; timeout=${timeoutMs} ms.`);
console.log('Each report covers only the latest window. Stop the generator container to stop traffic.');
const reportTimer = setInterval(report, reportMs);

try {
  while (!shutdown.signal.aborted) {
    const requestStartedAt = performance.now();
    try {
      const response = await fetch(target, {
        cache: 'no-store',
        redirect: 'error',
        // A new connection lets a Kubernetes Service select a pod on each request.
        headers: { Connection: 'close' },
        signal: AbortSignal.any([shutdown.signal, AbortSignal.timeout(timeoutMs)]),
      });
      // Any HTTP status is a completed response. Consume body and keep sending.
      await response.text();
      record(response.status);
    } catch {
      if (shutdown.signal.aborted) break;
      record();
    }

    // One request at a time, with no catch-up burst after slow or failed requests.
    const remaining = Math.max(0, intervalMs - (performance.now() - requestStartedAt));
    try {
      await sleep(remaining, undefined, { signal: shutdown.signal });
    } catch (error) {
      if (!shutdown.signal.aborted) throw error;
    }
  }
} finally {
  clearInterval(reportTimer);
  report();
  console.log(`total_completed=${completedTotal} total_success=${total.success} ` +
    `total_http_errors=${total.httpErrors} total_connection_errors=${total.connectionErrors}`);
  console.log('Traffic generator stopped.');
}
