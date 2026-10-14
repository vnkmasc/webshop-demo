#!/usr/bin/env bash
# Builds the webshop application and packs it with this target's deployment files:
#   release/shop-<version>.tar.gz
#     backend/shop-backend.jar  payment/payment-gateway.jar + Containerfile  risk/  frontend/dist/  nginx/  deploy/
# Usage: ./build-release.sh <version> [path/to/webshop]   (default: WEBSHOP_DIR or ../../../webshop)
# Run on a build machine with JDK 21 and Node 22 (not on the VMs).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-$(date +%Y%m%d%H%M)}"
APP="$(cd "${2:-${WEBSHOP_DIR:-${HERE}/../../../webshop}}" && pwd)"
[[ -f "${APP}/backend/pom.xml" && -f "${APP}/payment/Containerfile" ]] || { echo "webshop repo not found at ${APP}"; exit 1; }
OUT="${HERE}/release/shop-${VERSION}"

echo "==> Building from ${APP} ($(git -C "${APP}" describe --always --dirty 2>/dev/null || echo 'no git'))"
echo "==> Backend"
(cd "${APP}/backend" && ./mvnw -q -B clean package -DskipTests)
echo "==> Payment gateway"
(cd "${APP}/payment" && ./mvnw -q -B clean package -DskipTests)
echo "==> Front end"
(cd "${APP}/frontend" && npm ci --no-audit --no-fund && npm run build)

rm -rf "${OUT}"
mkdir -p "${OUT}/backend" "${OUT}/payment" "${OUT}/frontend"
cp "${APP}/backend/target/shop-backend.jar" "${OUT}/backend/"
cp "${APP}/payment/target/payment-gateway.jar" "${APP}/payment/Containerfile" "${OUT}/payment/"
# Python risk service: sources and Containerfile (the image is built on the app VM)
(cd "${APP}" && tar --exclude='__pycache__' -cf - risk) | tar -C "${OUT}" -xf -
cp -r "${APP}/frontend/dist" "${OUT}/frontend/dist"
cp -r "${HERE}/nginx" "${HERE}/deploy" "${OUT}/"
{
    echo "version=${VERSION}"
    echo "webshop=$(git -C "${APP}" rev-parse --verify -q HEAD || echo unknown)"
    echo "demo=$(git -C "${HERE}" rev-parse --verify -q HEAD || echo unknown)"
} > "${OUT}/VERSION"

tar -C "${HERE}/release" -czf "${HERE}/release/shop-${VERSION}.tar.gz" "shop-${VERSION}"
echo "==> ${HERE}/release/shop-${VERSION}.tar.gz"
