#!/usr/bin/env bash
# Builds the load generator image (Containerfile next to this script), tagged with the git commit and "current".
#   ./build-image.sh                        # build only
#   ./build-image.sh --push REGISTRY/PROJ   # build and push REGISTRY/PROJ/shop-load:<tag> (log in first)
#   ./build-image.sh --import-local         # build and load it into this node's containerd (Kubernetes, no registry)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILDER="$(command -v podman || command -v docker || true)"
[[ -n "$BUILDER" ]] || { echo "podman or docker is required" >&2; exit 2; }
TAG="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M)"
NAME=localhost/shop-load

"$BUILDER" build -f "$HERE/Containerfile" -t "$NAME:$TAG" -t "$NAME:current" "$HERE"
echo "built $NAME:$TAG"

case "${1:-}" in
  --push)
    [[ -n "${2:-}" ]] || { echo "usage: $0 --push REGISTRY/PROJECT" >&2; exit 2; }
    for t in "$TAG" current; do
      "$BUILDER" tag "$NAME:$t" "$2/shop-load:$t"
      "$BUILDER" push "$2/shop-load:$t"
    done
    echo "pushed $2/shop-load:$TAG" ;;
  --import-local)
    tmp="$(mktemp --suffix=.tar)"; trap 'rm -f "$tmp"' EXIT
    "$BUILDER" save -o "$tmp" "$NAME:$TAG" "$NAME:current"
    sudo ctr -n k8s.io images import "$tmp"
    echo "imported $NAME:$TAG into containerd on $(hostname)" ;;
  "") ;;
  *) echo "unknown option $1" >&2; exit 2 ;;
esac
