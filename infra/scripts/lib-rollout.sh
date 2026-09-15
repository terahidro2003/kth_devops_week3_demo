#!/usr/bin/env bash
# Shared helpers for demo Rollout recover / canary scripts.
# shellcheck shell=bash

set_rollout_image() {
  local image="$1"
  local stamp="$2"
  kubectl patch rollout demo --type=json \
    -p="[
      {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${image}\"},
      {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/demo.kth~1restartedAt\",\"value\":\"${stamp}\"}
    ]" >/dev/null
}

# Skip remaining canary steps (analysis/pauses) so an aborted Rollout can become Healthy.
promote_full() {
  kubectl patch rollout demo --subresource=status --type=merge \
    -p '{"status":{"abort":false,"promoteFull":true}}' >/dev/null 2>&1 \
    || kubectl patch rollout demo --type=merge \
      -p '{"status":{"abort":false,"promoteFull":true}}' >/dev/null 2>&1 \
    || true
}

# Failed AnalysisRuns are children of the Rollout and keep the Argo CD app Degraded.
delete_analysis_runs() {
  kubectl delete analysisrun -l app=demo --ignore-not-found >/dev/null 2>&1 || true
  # Rollouts-created runs use this owner label / name prefix.
  kubectl delete analysisrun -l rollouts.argoproj.io/resource-type=AnalysisRun --ignore-not-found >/dev/null 2>&1 || true
  local runs
  runs="$(kubectl get analysisrun -o name 2>/dev/null | grep -E 'demo|canary' || true)"
  if [[ -n "${runs}" ]]; then
    # shellcheck disable=SC2086
    kubectl delete ${runs} --ignore-not-found >/dev/null 2>&1 || true
  fi
}

wait_rollout_healthy() {
  local deadline=$((SECONDS + "${1:-120}"))
  local phase
  while (( SECONDS < deadline )); do
    phase="$(kubectl get rollout demo -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Healthy" ]]; then
      delete_analysis_runs
      return 0
    fi
    # Re-assert promote while Progressing through canary steps after a reset.
    if [[ "${phase}" == "Progressing" || "${phase}" == "Degraded" || "${phase}" == "Paused" ]]; then
      promote_full
    fi
    sleep 2
  done
  echo "Timed out waiting for Rollout Healthy (phase=${phase:-?})." >&2
  kubectl get rollout demo -o wide >&2 || true
  kubectl get pods -l app=demo -o wide >&2 || true
  return 1
}

# Make desired=v1, skip canary analysis, clear failed AnalysisRuns → Argo CD Healthy.
restore_healthy_v1() {
  local stamp="${1:-recover-$(date -u +%Y%m%dT%H%M%S)}"
  echo "Restoring Healthy baseline (demo:v1, promote-full)..."
  set_rollout_image "demo:v1" "${stamp}"
  sleep 1
  promote_full
  delete_analysis_runs
  wait_rollout_healthy 120
}
