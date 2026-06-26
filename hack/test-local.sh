#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="chrony-test"
PORT_FORWARD_PID=""

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    log_info "Cleaning up resources..."
    if [ -n "${PORT_FORWARD_PID}" ]; then
        log_info "Killing port-forward process (PID: ${PORT_FORWARD_PID})"
        kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    fi
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_info "Deleting KinD cluster '${CLUSTER_NAME}'..."
        kind delete cluster --name "${CLUSTER_NAME}"
    fi
}

# Trap exit/errors to always clean up
trap cleanup EXIT

# ---------------------------------------------------------
# 1. VERIFY TOOL DEPENDENCIES
# ---------------------------------------------------------
for tool in docker kind kubectl curl; do
    if ! command -v "${tool}" &>/dev/null; then
        log_error "Required tool '${tool}' is not installed."
        exit 1
    fi
done

# ---------------------------------------------------------
# 2. BUILD IMAGES LOCALLY
# ---------------------------------------------------------
log_info "Building main Chrony Docker image..."
docker build -t local-chrony:test .

log_info "Building Chrony Exporter Docker image..."
docker build -f Dockerfile.exporter -t local-chrony-exporter:test .

# ---------------------------------------------------------
# 3. CREATE KIND CLUSTER
# ---------------------------------------------------------
log_info "Creating KinD cluster '${CLUSTER_NAME}'..."
kind create cluster --name "${CLUSTER_NAME}"

# ---------------------------------------------------------
# 4. LOAD IMAGES INTO KIND
# ---------------------------------------------------------
log_info "Loading main Chrony image into KinD..."
kind load docker-image local-chrony:test --name "${CLUSTER_NAME}"

log_info "Loading Chrony Exporter image into KinD..."
kind load docker-image local-chrony-exporter:test --name "${CLUSTER_NAME}"

# ---------------------------------------------------------
# 5. DEPLOY TO KUBERNETES
# ---------------------------------------------------------
log_info "Applying ConfigMap..."
kubectl apply -f kubernetes/configmap.yaml

log_info "Applying DaemonSet with local images..."
sed -e "s|image: ghcr.io/containdk/chrony:latest|image: local-chrony:test|g" \
    -e "s|image: ghcr.io/containdk/chrony-exporter:latest|image: local-chrony-exporter:test|g" \
    kubernetes/daemonset.yaml | kubectl apply -f -

# ---------------------------------------------------------
# 6. WAIT FOR POD READY
# ---------------------------------------------------------
log_info "Waiting for DaemonSet pod to become ready..."
# Wait up to 60 seconds
kubectl rollout status daemonset/ntp-server -n kube-system --timeout=60s

log_info "Retrieving DaemonSet pod name..."
POD_NAME=""
for i in {1..10}; do
    POD_NAME=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=ntp-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${POD_NAME}" ]; then
        break
    fi
    log_info "Pod not yet listable, retrying in 2 seconds..."
    sleep 2
done

if [ -z "${POD_NAME}" ]; then
    log_error "Failed to retrieve DaemonSet pod name."
    exit 1
fi

log_info "Pod '${POD_NAME}' is ready."

# Check container logs
log_info "=== Chrony Container Logs ==="
kubectl logs -n kube-system "${POD_NAME}" -c chrony

log_info "=== Chrony Exporter Logs ==="
kubectl logs -n kube-system "${POD_NAME}" -c chrony-exporter

# ---------------------------------------------------------
# 7. PORT-FORWARD AND VERIFY METRICS
# ---------------------------------------------------------
log_info "Starting port-forward in background..."
kubectl port-forward -n kube-system "${POD_NAME}" 9123:9123 &
PORT_FORWARD_PID=$!

# Wait for port-forward to establish
sleep 3

log_info "Fetching metrics..."
METRICS=$(curl -s http://127.0.0.1:9123/metrics)

log_info "Asserting that metrics are valid..."
if echo "${METRICS}" | grep -q "chrony_up 1"; then
    log_info "Success: 'chrony_up 1' metric detected!"
else
    log_error "Failure: 'chrony_up 1' metric was not found in exporter output."
    echo "${METRICS}"
    exit 1
fi

log_info "All local tests passed successfully!"
