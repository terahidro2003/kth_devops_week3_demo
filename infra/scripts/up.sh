#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="devops-demo"
GOOD_IMAGE="weather:v1"
BAD_IMAGE="weather:v2"
ARGOCD_VERSION="v2.14.11"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
ARGO_ROLLOUTS_VERSION="v1.7.2"
ARGO_ROLLOUTS_INSTALL_URL="https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml"

# Optional: export GIT_REPO_URL=https://github.com/<you>/<repo>.git
# If unset, up.sh tries `git remote get-url origin`, then falls back to kubectl apply.
# Argo CD in-cluster has no SSH agent, so normalize git@ / ssh:// remotes to HTTPS.
GIT_REPO_URL="${GIT_REPO_URL:-}"
if [[ -z "${GIT_REPO_URL}" ]] && git -C "${ROOT_DIR}" remote get-url origin >/dev/null 2>&1; then
  GIT_REPO_URL="$(git -C "${ROOT_DIR}" remote get-url origin)"
fi
if [[ -n "${GIT_REPO_URL}" ]]; then
  if [[ "${GIT_REPO_URL}" =~ ^git@([^:]+):(.+)$ ]]; then
    GIT_REPO_URL="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "${GIT_REPO_URL}" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
    GIT_REPO_URL="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  GIT_REPO_URL="${GIT_REPO_URL%.git}.git"
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

echo "==> Building app images ${GOOD_IMAGE} (healthy) and ${BAD_IMAGE} (50% HTTP 500)..."
docker build -t "${GOOD_IMAGE}" --target good "${ROOT_DIR}/app"
docker build -t "${BAD_IMAGE}" --target bad "${ROOT_DIR}/app"

echo "==> Loading images into kind..."
kind load docker-image "${GOOD_IMAGE}" --name "${CLUSTER_NAME}"
kind load docker-image "${BAD_IMAGE}" --name "${CLUSTER_NAME}"

echo "==> Installing Argo Rollouts ${ARGO_ROLLOUTS_VERSION}..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f "${ARGO_ROLLOUTS_INSTALL_URL}"
kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=180s

echo "==> Installing Argo CD ${ARGOCD_VERSION}..."
kubectl apply -f "${ROOT_DIR}/infra/argocd/namespace.yaml"
kubectl apply -n argocd -f "${ARGOCD_INSTALL_URL}"
# Re-apply NodePort after install so the UI is reachable via kind port-mapping
kubectl apply -f "${ROOT_DIR}/infra/argocd/nodeport-service.yaml"
kubectl apply -f "${ROOT_DIR}/infra/argocd/version.yaml"

echo "==> Waiting for Argo CD components..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

disable_argocd_autosync() {
  # Prevent selfHeal from reverting local kubectl bootstrap / canary image patches.
  # Merge patch must set automated:null; omitting it leaves selfHeal enabled.
  local app
  for app in demo prometheus grafana; do
    if kubectl -n argocd get "application/${app}" >/dev/null 2>&1; then
      kubectl -n argocd patch "application/${app}" --type=merge \
        -p '{"spec":{"syncPolicy":{"automated":null,"syncOptions":["CreateNamespace=true"]}}}' >/dev/null
    fi
  done
}

bootstrap_with_kubectl() {
  echo "==> Bootstrapping workloads with kubectl apply..."
  if kubectl -n argocd get application demo >/dev/null 2>&1; then
    echo "==> Disabling Argo CD auto-sync so Git cannot overwrite local manifests..."
    disable_argocd_autosync
  fi
  # Ensure no leftover Deployment from older demos shares app=demo selectors.
  kubectl delete deployment demo --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f "${ROOT_DIR}/infra/app"
  kubectl apply -f "${ROOT_DIR}/infra/monitoring/prometheus"
  kubectl apply -f "${ROOT_DIR}/infra/monitoring/grafana"
}

wait_for_argo_apps() {
  # Only wait for Synced: demo Rollout stays Progressing until pods are Ready.
  local deadline=$((SECONDS + 90))
  local app sync msg
  while (( SECONDS < deadline )); do
    local all_ok=1
    for app in demo prometheus grafana; do
      sync="$(kubectl -n argocd get "application/${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
      msg="$(kubectl -n argocd get "application/${app}" -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || true)"
      echo "    ${app}: sync=${sync:-?}"
      if [[ -n "${msg}" && "${msg}" == *"failed"* ]]; then
        echo "    ${app} error: ${msg}"
        return 1
      fi
      if [[ "${sync}" != "Synced" ]]; then
        all_ok=0
      fi
    done
    if (( all_ok == 1 )); then
      return 0
    fi
    sleep 5
  done
  return 1
}

wait_for_demo_rollout() {
  local deadline=$((SECONDS + 180))
  local phase image waiting
  while (( SECONDS < deadline )); do
    phase="$(kubectl get rollout demo -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    image="$(kubectl get rollout demo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    waiting="$(kubectl get pods -l app=demo -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null || true)"
    echo "    demo rollout phase=${phase:-?} image=${image:-?}"
    if [[ "${waiting}" == *"ErrImageNeverPull"* || "${waiting}" == *"ImagePullBackOff"* ]]; then
      echo "==> Demo pods cannot pull '${image}'. Load ${GOOD_IMAGE} into kind (up.sh does this)."
      kubectl get pods -l app=demo -o wide
      return 1
    fi
    if [[ "${phase}" == "Healthy" ]]; then
      return 0
    fi
    sleep 5
  done
  echo "==> Timed out waiting for demo Rollout. Pods:"
  kubectl get pods -l app=demo -o wide || true
  return 1
}

if [[ -n "${GIT_REPO_URL}" ]]; then
  echo "==> Registering Argo CD Applications from ${GIT_REPO_URL}..."
  # Strip CR so Windows-checked-out YAML cannot poison the repo URL.
  sed "s|GIT_REPO_URL_PLACEHOLDER|${GIT_REPO_URL}|g; s/\r$//" \
    "${ROOT_DIR}/infra/argocd/applications/apps.yaml" | kubectl apply -f -

  echo "==> Waiting for Argo CD apps to sync (up to ~90s)..."
  if ! wait_for_argo_apps; then
    echo "==> Argo CD sync did not finish — falling back to kubectl apply"
    bootstrap_with_kubectl
  else
    # Prefer local manifests so an unpushed weather:v1 Rollout still boots.
    desired_image="$(kubectl get rollout demo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    if [[ "${desired_image}" != "${GOOD_IMAGE}" ]]; then
      echo "==> Git synced image '${desired_image}' != ${GOOD_IMAGE}; applying local manifests..."
      bootstrap_with_kubectl
    fi
  fi
else
  echo "==> No GIT_REPO_URL / git remote — bootstrapping workloads with kubectl apply"
  echo "    (Set GIT_REPO_URL or add a git remote to manage them via Argo CD instead.)"
  bootstrap_with_kubectl
fi

echo "==> Waiting for workloads to become ready..."
if ! wait_for_demo_rollout; then
  echo "==> Demo Rollout failed to become Healthy."
  exit 1
fi
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
echo "Canary demo:"
echo "  ./infra/scripts/load.sh          # generate traffic (keep running)"
echo "  ./infra/scripts/deploy-bad.sh     # weather:v2 canary 50% → >10 5xx in 1m → auto-rollback"
echo "  ./infra/scripts/deploy-good.sh    # weather:v1 canary 50% → ≤10 5xx budget → promote"
echo
echo "Node roles:"
kubectl get nodes -L role
echo
echo "Pods:"
kubectl get pods -A -o wide
echo
echo "Rollout:"
kubectl get rollout demo -o wide 2>/dev/null || true
