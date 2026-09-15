#!/usr/bin/env bash
# Live demo: canary to demo:v2. Safe to re-run after abort (clears Degraded first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-rollout.sh
source "${SCRIPT_DIR}/lib-rollout.sh"

stamp="$(date -u +%Y%m%dT%H%M%S)"

restore_healthy_v1 "reset-${stamp}"

echo "Starting canary demo:v2..."
set_rollout_image "demo:v2" "bad-${stamp}"
echo "Canary started (demo:v2). Watch Argo CD UI — start load.sh so latency analysis can fail."
