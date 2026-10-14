#!/usr/bin/env bash
# Application VM (RHEL 9). Idempotent.
#   shop-backend: Java process managed by systemd (OpenJDK 21 from AppStream)
#   shop-payment: Docker container (Docker CE from download.docker.com) supervised by systemd
#   shop-risk:    Docker container (Python risk scoring) supervised by systemd
# Usage: sudo ./install.sh [/etc/shop/app.env]
# Then deploy: sudo ./deploy.sh payment ../../payment/payment-gateway.jar
#              sudo ./deploy.sh backend ../../backend/shop-backend.jar
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../common/lib.sh
source "${HERE}/../common/lib.sh"
require_root
require_rhel9

ENV_FILE="${1:-/etc/shop/app.env}"
load_env "${ENV_FILE}" DB_HOST DB_PASSWORD PAYMENT_DB_PASSWORD PAYMENT_API_KEY JWT_SECRET FRONTEND_HOST ADMIN_SUBNET
check_secret DB_PASSWORD "${DB_PASSWORD}"
check_secret PAYMENT_DB_PASSWORD "${PAYMENT_DB_PASSWORD}"
check_secret PAYMENT_API_KEY "${PAYMENT_API_KEY}"
check_secret JWT_SECRET "${JWT_SECRET}"
check_secret APP_ADMIN_PASSWORD "${APP_ADMIN_PASSWORD:-}"
(( ${#JWT_SECRET} >= 32 )) || die "JWT_SECRET must be at least 32 characters"
if [[ "${ENV_FILE}" != /etc/shop/app.env ]]; then
    install -D -m 600 "${ENV_FILE}" /etc/shop/app.env
fi
chmod 600 /etc/shop/app.env

log "Installing OpenJDK 21 (AppStream)"
pkg_install java-21-openjdk-headless curl dnf-plugins-core
java -version

log "Installing Docker CE (download.docker.com repository for RHEL 9)"
# Docker rather than Podman: RHEL 9.8 ships crun 1.2x, which monitoring agents may not support for
# automatic injection into Podman containers, while Docker containers (runc) are widely supported.
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
fi
# containerd.io replaces the RHEL runc package; Podman keeps working with crun.
pkg_install --allowerasing docker-ce docker-ce-cli containerd.io
systemctl enable --now docker >/dev/null
docker --version
log "Pulling the container base images"
docker pull -q "$(awk '/^FROM /{print $2; exit}' "${HERE}/../../payment/Containerfile")" >/dev/null
if [[ -f "${HERE}/../../risk/Containerfile" ]]; then
    docker pull -q "$(awk '/^FROM /{print $2; exit}' "${HERE}/../../risk/Containerfile")" >/dev/null
fi

log "Creating user and directories"
id shop >/dev/null 2>&1 || useradd --system --home-dir /opt/shop --shell /sbin/nologin shop
install -d -o shop -g shop -m 755 /opt/shop /opt/shop/backend /var/log/shop
# Written by the container's user (uid 185 in the base image).
install -d -o 185 -g 0 -m 755 /var/log/shop-payment

log "Installing systemd units"
install -m 644 "${HERE}/shop-backend.service" /etc/systemd/system/shop-backend.service
systemctl daemon-reload
systemctl enable shop-backend >/dev/null
# Earlier layouts: a Podman/Quadlet unit, or the gateway as a plain Java service. Both are replaced.
if [[ -f /etc/containers/systemd/shop-payment.container ]]; then
    warn "Removing the Podman (Quadlet) shop-payment unit"
    systemctl stop shop-payment >/dev/null 2>&1 || true
    rm -f /etc/containers/systemd/shop-payment.container
    if command -v podman >/dev/null; then podman rm -f shop-payment >/dev/null 2>&1 || true; fi
elif [[ -f /etc/systemd/system/shop-payment.service ]] && ! grep -q 'docker run' /etc/systemd/system/shop-payment.service; then
    warn "Replacing the old shop-payment Java service with the container"
    systemctl disable --now shop-payment >/dev/null 2>&1 || true
fi
install -m 755 "${HERE}/payment-env.sh" /usr/local/sbin/shop-container-env
ln -sfn shop-container-env /usr/local/sbin/shop-payment-env
/usr/local/sbin/shop-container-env
install -m 644 "${HERE}/shop-payment.service" "${HERE}/shop-risk.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable shop-payment shop-risk >/dev/null

log "Checking connectivity to the database VM"
if timeout 5 bash -c "</dev/tcp/${DB_HOST}/${DB_PORT:-5432}"; then
    log "PostgreSQL ${DB_HOST}:${DB_PORT:-5432} reachable"
else
    warn "Cannot reach PostgreSQL at ${DB_HOST}:${DB_PORT:-5432} (check the database VM firewall / BACKEND_HOST)"
fi

log "Firewall: 8080 only from ${FRONTEND_HOST}, 8081 from ${ADMIN_SUBNET}; 8090 (payment) stays local"
ensure_firewalld
fw_allow_from "${FRONTEND_HOST}" 8080
fw_allow_from "${ADMIN_SUBNET}" 8081
fw_allow_from "${FRONTEND_HOST}" 8081   # readiness checks from the web VM
fw_apply

log "Application VM prepared. Deploy with: sudo ${HERE}/deploy.sh payment|backend <jar>  /  deploy.sh risk <risk dir>"
