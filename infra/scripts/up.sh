#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="devops-demo"
IMAGE_NAME="demo:local"
ARGOCD_VERSION="v2.14.11"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Optional: export GIT_REPO_URL=https://github.com/<you>/<repo>.git
# If unset, up.sh tries `git remote get-url origin`, then falls back to kubectl apply.
GIT_REPO_URL="${GIT_REPO_URL:-}"
if [[ -z "${GIT_REPO_URL}" ]] && git -C "${ROOT_DIR}" remote get-url origin >/dev/null 2>&1; then
  GIT_REPO_URL="$(git -C "${ROOT_DIR}" remote get-url origin)"
fi

echo "==> Creating kind cluster '${CLUSTER_NAME}' (1 control-plane + 7 workers)..."
kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT_DIR}/infra/kind/cluster.yaml"

echo "==> Labeling worker nodes by role..."
# kind names workers: devops-demo-worker, devops-demo-worker2, ... worker7
kubectl label node "${CLUSTER_NAME}-worker" role=prometheus --overwrite
kubectl label node "${CLUSTER_NAME}-worker2" role=grafana --overwrite
for i in 3 4 5 6 7; do
  kubectl label node "${CLUSTER_NAME}-worker${i}" role=app --overwrite
done

echo "==> Building app image ${IMAGE_NAME}..."
docker build -t "${IMAGE_NAME}" "${ROOT_DIR}/app"

echo "==> Loading image into kind..."
kind load docker-image "${IMAGE_NAME}" --name "${CLUSTER_NAME}"

echo "==> Installing Argo CD ${ARGOCD_VERSION}..."
kubectl apply -f "${ROOT_DIR}/infra/argocd/namespace.yaml"
kubectl apply -n argocd -f "${ARGOCD_INSTALL_URL}"
# Re-apply NodePort after install so the UI is reachable via kind port-mapping
kubectl apply -f "${ROOT_DIR}/infra/argocd/nodeport-service.yaml"
kubectl apply -f "${ROOT_DIR}/infra/argocd/version.yaml"

echo "==> Waiting for Argo CD server..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

if [[ -n "${GIT_REPO_URL}" ]]; then
  echo "==> Registering Argo CD Applications from ${GIT_REPO_URL}..."
  sed "s|GIT_REPO_URL_PLACEHOLDER|${GIT_REPO_URL}|g" \
    "${ROOT_DIR}/infra/argocd/applications/apps.yaml" | kubectl apply -f -

  echo "==> Waiting for Argo CD apps to sync (may take a minute)..."
  for app in demo prometheus grafana; do
    kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced "application/${app}" --timeout=300s || true
    kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy "application/${app}" --timeout=300s || true
  done
else
  echo "==> No GIT_REPO_URL / git remote — bootstrapping workloads with kubectl apply"
  echo "    (Set GIT_REPO_URL or add a git remote to manage them via Argo CD instead.)"
  kubectl apply -f "${ROOT_DIR}/infra/app"
  kubectl apply -f "${ROOT_DIR}/infra/monitoring/prometheus"
  kubectl apply -f "${ROOT_DIR}/infra/monitoring/grafana"
fi

echo "==> Waiting for workloads to become ready..."
kubectl rollout status deployment/demo --timeout=180s
kubectl rollout status deployment/prometheus --timeout=180s
kubectl rollout status deployment/grafana --timeout=180s

ARGOCD_PASSWORD="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

echo
echo "Cluster is up."
echo "  App:         http://localhost:8080/hello-world"
echo "  Prometheus:  http://localhost:9090"
echo "  Grafana:     http://localhost:3000  (admin / admin)"
echo "  Argo CD:     https://localhost:8081  (admin / ${ARGOCD_PASSWORD:-<see secret argocd-initial-admin-secret>})"
echo "               (accept the self-signed certificate warning)"
echo
echo "Node roles:"
kubectl get nodes -L role
echo
echo "Pods:"
kubectl get pods -A -o wide
