#!/usr/bin/env bash
# Deploy weather:v2 as a canary; AnalysisTemplate should fail → automatic rollback.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="devops-demo"
BAD_IMAGE="weather:v2"

echo "==> Ensuring ${BAD_IMAGE} is in kind..."
docker image inspect "${BAD_IMAGE}" >/dev/null 2>&1 \
  || docker build -t "${BAD_IMAGE}" --target bad "${ROOT_DIR}/app"
kind load docker-image "${BAD_IMAGE}" --name "${CLUSTER_NAME}"

# Avoid Argo CD selfHeal reverting weather:v2 → Git's weather:v1 (that skips canary steps).
# Merge patch must set automated:null; omitting it leaves selfHeal enabled.
if kubectl -n argocd get application demo >/dev/null 2>&1; then
  echo "==> Disabling Argo CD auto-sync for application/demo..."
  kubectl -n argocd patch application demo --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null,"syncOptions":["CreateNamespace=true"]}}}'
fi

# Old Deployment (pre-Rollout) shares app=demo and breaks Services/endpoints.
kubectl delete deployment demo --ignore-not-found >/dev/null

echo "==> Applying latest Rollout/Analysis manifests..."
kubectl apply -f "${ROOT_DIR}/infra/app"

echo "==> Clearing any previous abort so a new canary can start..."
kubectl patch rollout demo --type=merge --subresource=status \
  -p '{"abort":false,"abortedAt":null}' 2>/dev/null || true

# JSON patch only — merge patch would replace the whole containers[] and drop ports/probes.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "==> Patching Rollout image to ${BAD_IMAGE}..."
kubectl patch rollout demo --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${BAD_IMAGE}\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/demo.kth~1restartedAt\",\"value\":\"${TS}\"}
]"

echo "==> Watching canary (50% weight ≈ 2 bad + 2 good) → analysis → expected Abort/rollback..."
echo "    Keep ./infra/scripts/load.sh running so Prometheus sees canary 5xx counts (budget: 10)."
deadline=$((SECONDS + 360))
while (( SECONDS < deadline )); do
  phase="$(kubectl get rollout demo -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  weight="$(kubectl get rollout demo -o jsonpath='{.status.canary.weights.canary}' 2>/dev/null || true)"
  msg="$(kubectl get rollout demo -o jsonpath='{.status.message}' 2>/dev/null || true)"
  echo "    phase=${phase:-?} canaryWeight=${weight:-?} ${msg}"
  if [[ "${phase}" == "Degraded" || "${msg}" == *"Abort"* || "${msg}" == *"RolledBack"* || "${msg}" == *"rolled back"* ]]; then
    echo "==> Rollback observed."
    kubectl get rollout demo
    kubectl get pods -l app=demo -o wide
    exit 0
  fi
  if [[ "${phase}" == "Healthy" ]]; then
    echo "==> Unexpected Healthy without rollback (canary may have been reverted by Argo CD selfHeal)."
    kubectl describe rollout demo | tail -n 30
    exit 1
  fi
  if [[ "${msg}" == *"SkipSteps"* ]] || kubectl get events --field-selector involvedObject.name=demo --sort-by=.lastTimestamp 2>/dev/null | tail -n 5 | grep -q SkipSteps; then
    echo "==> Canary steps were skipped (often Argo CD selfHeal reverting the image). Aborting watch."
    kubectl -n argocd get application demo -o jsonpath='{.spec.syncPolicy}{"\n"}' 2>/dev/null || true
    exit 1
  fi
  sleep 5
done

echo "==> Timed out waiting for rollback."
kubectl describe rollout demo | tail -n 40
exit 1
