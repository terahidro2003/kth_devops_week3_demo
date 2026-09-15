#!/usr/bin/env bash
# ~10 rps against /hello-world; prints status/latency every 10 requests.
set -euo pipefail

URL="${URL:-http://localhost:8080/hello-world}"
SLEEP_SEC="${SLEEP_SEC:-0.1}"
WINDOW=10

echo "Hitting ${URL} every ${SLEEP_SEC}s (~10 rps). Ctrl+C to stop."

ok=0
err=0
lat_sum_ms=0
n=0

while true; do
  out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 5 "${URL}" 2>/dev/null || echo "err 0")"
  code="${out%% *}"
  secs="${out##* }"
  ms="$(awk -v s="${secs}" 'BEGIN { printf "%.0f", (s + 0) * 1000 }')"

  if [[ "${code}" =~ ^2 ]]; then
    ok=$((ok + 1))
  else
    err=$((err + 1))
  fi
  lat_sum_ms=$((lat_sum_ms + ms))
  n=$((n + 1))

  if (( n % WINDOW == 0 )); then
    avg=$((lat_sum_ms / WINDOW))
    echo "$(date +%H:%M:%S) last${WINDOW}: ok=${ok} err=${err} avg_latency_ms=${avg} (last=${code} ${ms}ms)"
    ok=0
    err=0
    lat_sum_ms=0
  fi
  sleep "${SLEEP_SEC}"
done
