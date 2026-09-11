#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="devops-demo"
IMAGE_NAME="demo:local"

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

echo "==> Deploying app..."
kubectl apply -f "${ROOT_DIR}/infra/app"

echo "==> Deploying Prometheus..."
kubectl apply -f "${ROOT_DIR}/infra/monitoring/prometheus"

echo "==> Deploying Grafana..."
kubectl apply -f "${ROOT_DIR}/infra/monitoring/grafana"

echo "==> Waiting for workloads to become ready..."
kubectl rollout status deployment/demo --timeout=180s
kubectl rollout status deployment/prometheus --timeout=180s
kubectl rollout status deployment/grafana --timeout=180s

echo
echo "Cluster is up."
echo "  App:         http://localhost:8080/hello-world"
echo "  Prometheus:  http://localhost:9090"
echo "  Grafana:     http://localhost:3000  (admin / admin)"
echo
echo "Node roles:"
kubectl get nodes -L role
echo
echo "Pods:"
kubectl get pods -o wide
