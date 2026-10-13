#!/usr/bin/env bash
# Deploys a new version of one service and rolls back automatically when it does not become healthy.
#   sudo ./deploy.sh backend path/to/shop-backend.jar     (Java process managed by systemd)
#   sudo ./deploy.sh payment path/to/payment-gateway.jar  (Docker image built here, container run by systemd)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../common/lib.sh
source "${HERE}/../common/lib.sh"
require_root

SERVICE="${1:?usage: deploy.sh backend|payment path/to/jar}"
JAR="${2:?usage: deploy.sh backend|payment path/to/jar}"
[[ -f "${JAR}" ]] || die "${JAR} not found"
WAIT_SECONDS="${WAIT_SECONDS:-300}"
IMAGE=shop-payment

wait_healthy() {
    local url="$1" waited=0
    while (( waited < WAIT_SECONDS )); do
        if curl -fs "${url}" | grep -q '"status":"UP"'; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

deploy_backend() {
    local target=/opt/shop/backend/shop-backend.jar health=http://127.0.0.1:8081/actuator/health/readiness
    if [[ -f "${target}" ]]; then
        cp -p "${target}" "${target}.prev"
    fi
    install -o shop -g shop -m 644 "${JAR}" "${target}"
    log "Restarting shop-backend"
    systemctl restart shop-backend
    if wait_healthy "${health}"; then
        log "shop-backend is healthy: $(curl -fs http://127.0.0.1:8081/actuator/info || true)"
        return 0
    fi
    warn "shop-backend did not become healthy within ${WAIT_SECONDS}s; last log lines:"
    journalctl -u shop-backend -n 60 --no-pager || true
    if [[ -f "${target}.prev" ]]; then
        warn "Rolling back to the previous jar"
        install -o shop -g shop -m 644 "${target}.prev" "${target}"
        systemctl restart shop-backend
        if wait_healthy "${health}"; then
            warn "Rolled back successfully"
        else
            die "Rollback also failed - check the logs"
        fi
    fi
    die "Deployment failed"
}

deploy_payment() {
    local containerfile health=http://127.0.0.1:8090/actuator/health/readiness tag ctx
    containerfile="$(dirname "${JAR}")/Containerfile"
    [[ -f "${containerfile}" ]] || containerfile="${HERE}/../../payment/Containerfile"
    [[ -f "${containerfile}" ]] || die "Containerfile not found next to ${JAR}"
    tag="$(date +%Y%m%d%H%M%S)"
    ctx="$(mktemp -d)"
    cp "${JAR}" "${ctx}/payment-gateway.jar"
    log "Building image ${IMAGE}:${tag}"
    if ! docker build -q -t "${IMAGE}:${tag}" -f "${containerfile}" "${ctx}" >/dev/null; then
        rm -rf "${ctx}"
        die "Image build failed"
    fi
    rm -rf "${ctx}"

    local had_current=false
    if docker image inspect "${IMAGE}:current" >/dev/null 2>&1; then
        docker tag "${IMAGE}:current" "${IMAGE}:prev"
        had_current=true
    fi
    docker tag "${IMAGE}:${tag}" "${IMAGE}:current"
    /usr/local/sbin/shop-payment-env
    log "Restarting shop-payment (container)"
    systemctl restart shop-payment
    if wait_healthy "${health}"; then
        log "shop-payment is healthy: $(curl -fs http://127.0.0.1:8090/actuator/info || true)"
        # Keep the three newest timestamped images (plus :current and :prev).
        docker images --format '{{.Tag}}' "${IMAGE}" | grep -E '^[0-9]{14}$' | sort -r | tail -n +4 \
            | xargs -r -I{} docker rmi "${IMAGE}:{}" >/dev/null 2>&1 || true
        return 0
    fi
    warn "shop-payment did not become healthy within ${WAIT_SECONDS}s; last log lines:"
    journalctl -u shop-payment -n 60 --no-pager || true
    if [[ "${had_current}" == true ]]; then
        warn "Rolling back to the previous image"
        docker tag "${IMAGE}:prev" "${IMAGE}:current"
        systemctl restart shop-payment
        if wait_healthy "${health}"; then
            warn "Rolled back successfully"
        else
            die "Rollback also failed - check the logs"
        fi
    fi
    die "Deployment failed"
}

case "${SERVICE}" in
    backend) deploy_backend ;;
    payment) deploy_payment ;;
    *) die "unknown service ${SERVICE} (backend|payment)" ;;
esac
