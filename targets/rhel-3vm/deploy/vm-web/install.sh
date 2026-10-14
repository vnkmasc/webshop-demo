#!/usr/bin/env bash
# Web VM (RHEL 9): nginx serving the React build and reverse-proxying /api to the application VM. Idempotent.
# Usage: sudo ./install.sh [/etc/shop/web.env]
# Then publish the front end: sudo ./deploy.sh ../../frontend/dist
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NGINX_SRC="$(cd "${HERE}/../../nginx" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../common/lib.sh
source "${HERE}/../common/lib.sh"
require_root
require_rhel9

ENV_FILE="${1:-/etc/shop/web.env}"
load_env "${ENV_FILE}" APP_DOMAIN BACKEND_UPSTREAM
if [[ "${ENV_FILE}" != /etc/shop/web.env ]]; then
    install -D -m 644 "${ENV_FILE}" /etc/shop/web.env
fi

log "Installing nginx"
# Prefer the newest nginx module stream available; fall back to the default stream.
dnf -y module reset nginx >/dev/null 2>&1 || true
dnf -y module enable nginx:1.24 >/dev/null 2>&1 || dnf -y module enable nginx:1.22 >/dev/null 2>&1 || true
pkg_install nginx gettext curl policycoreutils-python-utils
nginx -v

log "Installing configuration"
install -d /etc/nginx/snippets/shop /opt/shop/nginx/templates /etc/nginx/certs /var/www/certbot \
    /var/www/shop/releases
install -m 644 "${NGINX_SRC}/nginx.main.conf" /etc/nginx/nginx.conf
install -m 644 "${NGINX_SRC}"/snippets/*.conf /etc/nginx/snippets/shop/
install -m 644 "${NGINX_SRC}"/templates/*.template /opt/shop/nginx/templates/
install -m 755 "${NGINX_SRC}/render.sh" /opt/shop/nginx/render.sh
rm -f /etc/nginx/conf.d/default.conf

if [[ ! -e /var/www/shop/current ]]; then
    # Placeholder until the first front-end deployment.
    install -d /var/www/shop/releases/initial
    echo '<!doctype html><meta charset="utf-8"><title>Sai Buoc</title><p>Đang triển khai...</p>' \
        > /var/www/shop/releases/initial/index.html
    ln -sfn /var/www/shop/releases/initial /var/www/shop/current
fi

log "SELinux: allow nginx to proxy to the backend and serve /var/www/shop"
if command -v getenforce >/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    setsebool -P httpd_can_network_connect 1
    semanage fcontext -a -t httpd_sys_content_t '/var/www/shop(/.*)?' 2>/dev/null \
        || semanage fcontext -m -t httpd_sys_content_t '/var/www/shop(/.*)?'
    restorecon -R /var/www/shop /var/www/certbot /etc/nginx
fi

# Backend readiness state used by locations.conf; kept up to date by shop-upstream-check (see below).
if [[ ! -f /etc/nginx/shop-backend-state.conf ]]; then
    # shellcheck disable=SC2016  # $shop_backend_ready is an nginx variable, written literally
    printf '# Managed by shop-upstream-check: 1 = proxy /api/ to the backend, 0 = answer 503.\nset $shop_backend_ready 1;\n' \
        > /etc/nginx/shop-backend-state.conf
fi

cat > /usr/local/sbin/shop-render-nginx <<'RENDER'
#!/usr/bin/env bash
# Re-renders /etc/nginx/conf.d/shop.conf from /etc/shop/web.env (HTTPS if certificates exist).
set -euo pipefail
set -a
# shellcheck disable=SC1091
source /etc/shop/web.env
set +a
WEB_ROOT=/var/www/shop/current TEMPLATE_DIR=/opt/shop/nginx/templates \
    OUTPUT=/etc/nginx/conf.d/shop.conf /opt/shop/nginx/render.sh
command -v restorecon >/dev/null && restorecon /etc/nginx/conf.d/shop.conf || true
nginx -t
systemctl reload-or-restart nginx
RENDER
chmod 755 /usr/local/sbin/shop-render-nginx

# Room for worker_connections 4096 (the default 1024 open files is too low). Set by systemd because
# SELinux does not let nginx raise the limit itself (httpd_setrlimit is off).
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/limits.conf <<'LIMITS'
[Service]
LimitNOFILE=16384
LIMITS
systemctl daemon-reload
systemctl enable nginx >/dev/null
# Render and test the new configuration first; a running nginx is only restarted (to pick up the file limit)
# once the configuration is known to be valid, so a bad config never takes the site down.
/usr/local/sbin/shop-render-nginx
systemctl restart nginx

log "Backend readiness check every 5 s (shop-upstream-check.timer)"
install -m 755 "${HERE}/upstream-check.sh" /usr/local/sbin/shop-upstream-check
install -m 644 "${HERE}/shop-upstream-check.service" "${HERE}/shop-upstream-check.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now shop-upstream-check.timer >/dev/null

log "Firewall: SSH, HTTP, HTTPS"
ensure_firewalld
fw_allow_service http
fw_allow_service https
fw_apply

log "Checking the backend through nginx"
if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/api/site-config" | grep -qE '^200$'; then
    log "Backend reachable through nginx"
else
    warn "Backend not reachable via http://127.0.0.1/api/ (is the application VM running and is 8080 open to this VM?)"
fi
log "Web VM ready. Publish the front end with: sudo ${HERE}/deploy.sh <path/to/frontend/dist>"
