#!/usr/bin/env bash
# Restore Healthy baseline (demo:v1). Clears abort / Degraded in Rollouts + Argo CD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-rollout.sh
source "${SCRIPT_DIR}/lib-rollout.sh"

restore_healthy_v1 "good-$(date -u +%Y%m%dT%H%M%S)"
echo "Rollout is Healthy on demo:v1. Argo CD should show Healthy (OutOfSync is OK during live patches)."
