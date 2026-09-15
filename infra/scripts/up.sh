#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="devops-demo"
APP_NODE="${CLUSTER_NAME}-worker3"
GOOD_IMAGE="demo:v1"
BAD_IMAGE="demo:v2"
ARGOCD_VERSION="v2.14.11"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
ARGO_ROLLOUTS_VERSION="v1.7.2"
ARGO_ROLLOUTS_INSTALL_URL="https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml"

# Optional: export GIT_REPO_URL=https://github.com/<you>/<repo>.git
# If unset, up.sh tries `git remote get-url origin`, then falls back to kubectl apply.
# Local manifests + local images are always the source of truth for the demo Rollout
# (remote Git may still reference stale tags such as weather:v1).
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

require_docker_images() {
  local img
  for img in "${GOOD_IMAGE}" "${BAD_IMAGE}"; do
    if ! docker image inspect "${img}" >/dev/null 2>&1; then
      echo "ERROR: Docker image '${img}' not found on the host."
      echo "       Build may have been skipped or failed. Refusing to continue"
      echo "       (pods use imagePullPolicy: Never → ErrImageNeverPull)."
      exit 1
    fi
  done
}

# Load host images into every kind node and fail fast if the app worker lacks them.
load_images_into_kind() {
  require_docker_images

  echo "==> Loading ${GOOD_IMAGE} and ${BAD_IMAGE} into kind cluster '${CLUSTER_NAME}'..."
  kind load docker-image "${GOOD_IMAGE}" --name "${CLUSTER_NAME}"
  kind load docker-image "${BAD_IMAGE}" --name "${CLUSTER_NAME}"

  local listing
  if ! listing="$(docker exec "${APP_NODE}" crictl images 2>/dev/null)"; then
    echo "ERROR: Could not list images on ${APP_NODE} after kind load."
    echo "       Is the cluster up? kind load may have failed silently on Windows."
    exit 1
  fi
  # crictl columns look like: docker.io/library/demo   v1   <id>   <size>
  if ! grep -E 'demo[[:space:]]+v1([[:space:]]|$)' <<<"${listing}" >/dev/null; then
    echo "ERROR: '${GOOD_IMAGE}' is not present on ${APP_NODE} after kind load."
    echo "       crictl images (filtered):"
    grep -E 'demo|weather' <<<"${listing}" || echo "       (no demo/weather images)"
    exit 1
  fi
  if ! grep -E 'demo[[:space:]]+v2([[:space:]]|$)' <<<"${listing}" >/dev/null; then
    echo "ERROR: '${BAD_IMAGE}' is not present on ${APP_NODE} after kind load."
    exit 1
  fi
  echo "    Verified ${GOOD_IMAGE} and ${BAD_IMAGE} on ${APP_NODE}."
}

echo "==> Creating kind cluster '${CLUSTER_NAME}' (1 control-plane + 3 workers)..."
kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT_DIR}/infra/kind/cluster.yaml"

echo "==> Labeling worker nodes by role..."
kubectl label node "${CLUSTER_NAME}-worker" role=prometheus --overwrite
kubectl label node "${CLUSTER_NAME}-worker2" role=grafana --overwrite
kubectl label node "${CLUSTER_NAME}-worker3" role=app --overwrite

echo "==> Building app images ${GOOD_IMAGE} (fast) and ${BAD_IMAGE} (~1500ms latency)..."
docker build -t "${GOOD_IMAGE}" --target good "${ROOT_DIR}/app"
docker build -t "${BAD_IMAGE}" --target bad "${ROOT_DIR}/app"
require_docker_images

load_images_into_kind

echo "==> Installing Argo Rollouts ${ARGO_ROLLOUTS_VERSION}..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f "${ARGO_ROLLOUTS_INSTALL_URL}"
kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=180s

echo "==> Installing Argo CD ${ARGOCD_VERSION}..."
kubectl apply -f "${ROOT_DIR}/infra/argocd/namespace.yaml"
kubectl apply -n argocd -f "${ARGOCD_INSTALL_URL}"
kubectl apply -f "${ROOT_DIR}/infra/argocd/nodeport-service.yaml"
kubectl apply -f "${ROOT_DIR}/infra/argocd/version.yaml"

echo "==> Waiting for Argo CD components..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

echo "==> Ignoring AnalysisRun health in Argo CD (failed canaries otherwise leave App Degraded)..."
kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"resource.customizations.health.argoproj.io_AnalysisRun":"hs = {}\nhs.status = \"Healthy\"\nhs.message = \"Ignored: canary gate is reflected on the Rollout\"\nreturn hs\n"}}'
kubectl -n argocd rollout restart statefulset/argocd-application-controller >/dev/null 2>&1 || true
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s >/dev/null 2>&1 || true

disable_argocd_autosync() {
  # Prevent selfHeal from reverting local kubectl / canary image patches.
  local app
  for app in demo prometheus grafana; do
    if kubectl -n argocd get "application/${app}" >/dev/null 2>&1; then
      kubectl -n argocd patch "application/${app}" --type=merge \
        -p '{"spec":{"syncPolicy":{"automated":null,"syncOptions":["CreateNamespace=true"]}}}' >/dev/null
    fi
  done
}

bootstrap_with_kubectl() {
  echo "==> Bootstrapping workloads with local manifests (source of truth: ${GOOD_IMAGE})..."
  if kubectl -n argocd get application demo >/dev/null 2>&1; then
    echo "==> Disabling Argo CD auto-sync so Git cannot overwrite local manifests..."
    disable_argocd_autosync
  fi
  # Drop any Git-synced Rollout first so we do not canary-upgrade from a stale
  # image (e.g. weather:v1) and leave mixed ReplicaSets / ErrImageNeverPull.
  kubectl delete rollout demo --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete deployment demo --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pods -l app=demo --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f "${ROOT_DIR}/infra/app"
  kubectl apply -f "${ROOT_DIR}/infra/monitoring/prometheus"
  kubectl apply -f "${ROOT_DIR}/infra/monitoring/grafana"
}

wait_for_monitoring_apps() {
  local deadline=$((SECONDS + 90))
  local app sync msg
  while (( SECONDS < deadline )); do
    local all_ok=1
    for app in prometheus grafana; do
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
  local phase image waiting message
  while (( SECONDS < deadline )); do
    phase="$(kubectl get rollout demo -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    image="$(kubectl get rollout demo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    message="$(kubectl get rollout demo -o jsonpath='{.status.message}' 2>/dev/null || true)"
    waiting="$(kubectl get pods -l app=demo -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null || true)"
    echo "    demo rollout phase=${phase:-?} image=${image:-?}"
    if [[ -n "${message}" ]]; then
      echo "      message: ${message}"
    fi
    if [[ "${phase}" == "Degraded" && "${message}" == *"InvalidSpec"* ]]; then
      echo "==> Rollout spec is invalid — fix infra/app/rollout.yaml and re-apply."
      return 1
    fi
    if [[ -n "${image}" && "${image}" != "${GOOD_IMAGE}" && "${image}" != "${BAD_IMAGE}" ]]; then
      echo "==> Rollout still wants '${image}' (expected ${GOOD_IMAGE}). Git may have re-synced a stale tag."
      kubectl get pods -l app=demo -o wide || true
      return 1
    fi
    if [[ "${waiting}" == *"ErrImageNeverPull"* || "${waiting}" == *"ImagePullBackOff"* ]]; then
      echo "==> Demo pods cannot use '${image:-?}' (imagePullPolicy: Never)."
      echo "    Host must have the image and kind load must have succeeded for '${CLUSTER_NAME}'."
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
  kubectl get rollout demo -o yaml | sed -n '/^status:/,$p' || true
  return 1
}

if [[ -n "${GIT_REPO_URL}" ]]; then
  echo "==> Registering Argo CD Applications from ${GIT_REPO_URL}..."
  sed "s|GIT_REPO_URL_PLACEHOLDER|${GIT_REPO_URL}|g; s/\r$//" \
    "${ROOT_DIR}/infra/argocd/applications/apps.yaml" | kubectl apply -f -

  # Demo stays manual-sync; clear automated policy so selfHeal cannot fight local apply.
  echo "==> Ensuring Applications are not selfHealing against live demo patches..."
  disable_argocd_autosync

  # Sync monitoring from Git only. Demo image correctness comes from local manifests
  # (remote may still have weather:v1 or other stale tags).
  echo "==> Triggering Argo CD sync for prometheus/grafana (demo uses local manifests)..."
  for app in prometheus grafana; do
    kubectl -n argocd patch "application/${app}" --type=merge \
      -p '{"operation":{"initiatedBy":{"username":"up.sh"},"sync":{"revision":"HEAD"}}}' >/dev/null 2>&1 || true
  done

  echo "==> Waiting for monitoring apps to sync (up to ~90s)..."
  if ! wait_for_monitoring_apps; then
    echo "==> Argo CD monitoring sync did not finish — will apply local monitoring manifests too"
  fi
else
  echo "==> No GIT_REPO_URL / git remote — bootstrapping all workloads with kubectl apply"
  echo "    (Set GIT_REPO_URL or add a git remote to manage monitoring via Argo CD.)"
fi

# Always re-load + apply local demo manifests so stale Git tags never stick.
load_images_into_kind
bootstrap_with_kubectl

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
echo "  ./infra/scripts/load.sh          # ~10 rps (keep running)"
echo "  ./infra/scripts/deploy-bad.sh     # set image demo:v2 → latency analysis → auto-rollback"
echo "  ./infra/scripts/deploy-good.sh    # set image demo:v1 → promote"
echo
echo "Node roles:"
kubectl get nodes -L role
echo
echo "Pods:"
kubectl get pods -A -o wide
echo
echo "Rollout:"
kubectl get rollout demo -o wide 2>/dev/null || true
