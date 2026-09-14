#!/usr/bin/env bash
# Deploy weather:v1 as a canary; AnalysisTemplate should pass → promote to 100%.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="devops-demo"
GOOD_IMAGE="weather:v1"

echo "==> Ensuring ${GOOD_IMAGE} is in kind..."
docker image inspect "${GOOD_IMAGE}" >/dev/null 2>&1 \
  || docker build -t "${GOOD_IMAGE}" --target good "${ROOT_DIR}/app"
kind load docker-image "${GOOD_IMAGE}" --name "${CLUSTER_NAME}"

# Avoid Argo CD selfHeal reverting live demo changes.
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
echo "==> Patching Rollout image to ${GOOD_IMAGE}..."
kubectl patch rollout demo --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${GOOD_IMAGE}\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/demo.kth~1restartedAt\",\"value\":\"${TS}\"}
]"

echo "==> Watching canary (50% weight ≈ 2 new + 2 stable) → analysis → expected promote..."
echo "    Keep ./infra/scripts/load.sh running so Prometheus sees canary 5xx counts (budget: 10)."
deadline=$((SECONDS + 360))
while (( SECONDS < deadline )); do
  phase="$(kubectl get rollout demo -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  weight="$(kubectl get rollout demo -o jsonpath='{.status.canary.weights.canary}' 2>/dev/null || true)"
  msg="$(kubectl get rollout demo -o jsonpath='{.status.message}' 2>/dev/null || true)"
  echo "    phase=${phase:-?} canaryWeight=${weight:-?} ${msg}"
  if [[ "${phase}" == "Healthy" ]]; then
    echo "==> Promote complete."
    kubectl get rollout demo
    kubectl get pods -l app=demo -o wide
    exit 0
  fi
  if [[ "${phase}" == "Degraded" || "${msg}" == *"InconclusiveAnalysisRun"* ]]; then
    echo "==> Unexpected degrade/inconclusive."
    kubectl get endpoints demo demo-canary demo-stable
    exit 1
  fi
  sleep 5
done

echo "==> Timed out waiting for promote."
kubectl describe rollout demo | tail -n 40
exit 1
