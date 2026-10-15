#!/usr/bin/env bash
# Deploys the background load to the current kubectl context.
#   ./deploy.sh BASE_URL [IMAGE]
# ADMIN_PASSWORD must be set in the environment (the admin persona processes orders and restocks).
# Without IMAGE it uses localhost/shop-load:current imported with ../build-image.sh --import-local, and pins the
# pod to this node (the only one that has the image), tolerating the control-plane taint.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE_URL="${1:?usage: $0 BASE_URL [IMAGE]}"
IMAGE="${2:-}"
: "${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"

kubectl apply -f "$HERE/shop-load.yaml"
kubectl -n shop-load patch configmap shop-load --type merge -p "{\"data\":{\"BASE_URL\":\"$BASE_URL\"}}"
kubectl -n shop-load create secret generic shop-load --from-literal=ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "$IMAGE" ]]; then
  kubectl -n shop-load set image deploy/shop-load k6="$IMAGE"
else
  node="$(kubectl get node -o name | grep -x "node/$(hostname -s)" | cut -d/ -f2)"
  [[ -n "$node" ]] || { echo "this machine is not a node of the cluster: pass IMAGE from a registry" >&2; exit 2; }
  kubectl -n shop-load patch deploy shop-load --type strategic -p "{\"spec\":{\"template\":{\"spec\":{
    \"nodeSelector\":{\"kubernetes.io/hostname\":\"$node\"},
    \"tolerations\":[{\"key\":\"node-role.kubernetes.io/control-plane\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"}],
    \"containers\":[{\"name\":\"k6\",\"imagePullPolicy\":\"Never\"}]}}}}"
fi
kubectl -n shop-load rollout restart deploy/shop-load
kubectl -n shop-load rollout status deploy/shop-load --timeout=120s
