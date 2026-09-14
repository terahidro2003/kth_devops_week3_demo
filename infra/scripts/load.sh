#!/usr/bin/env bash
# Generate steady traffic so Prometheus has canary samples during analysis.
set -euo pipefail

URL="${URL:-http://localhost:8080/hello-world}"
SLEEP_SEC="${SLEEP_SEC:-0.2}"

echo "Hitting ${URL} every ${SLEEP_SEC}s (Ctrl+C to stop)..."
while true; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${URL}" || echo err)"
  echo "$(date +%H:%M:%S) ${code}"
  sleep "${SLEEP_SEC}"
done
