#!/usr/bin/env bash
# Active health check of the backend, as a load balancer would do: polls the backend readiness endpoint and
# switches nginx between proxying /api/ and answering 503. Out of rotation after 2 consecutive failed checks,
# back in after 1 successful check. Runs every 5 s from shop-upstream-check.timer; reloads nginx only on change.
set -euo pipefail
set -a
# shellcheck disable=SC1091
source /etc/shop/web.env
set +a
URL="${BACKEND_HEALTH_URL:-http://${BACKEND_UPSTREAM%:*}:8081/actuator/health/readiness}"
STATE_FILE=/etc/nginx/shop-backend-state.conf
FAILS_FILE=/run/shop-upstream-check.fails

if curl -s -m 2 "${URL}" | grep -q '^{"status":"UP"'; then
    fails=0
else
    fails=$(( $(cat "${FAILS_FILE}" 2>/dev/null || echo 0) + 1 ))
fi
echo "${fails}" > "${FAILS_FILE}"

if (( fails == 0 )); then
    want=1
elif (( fails >= 2 )); then
    want=0
else
    exit 0
fi
current="$(grep -oE 'shop_backend_ready [01]' "${STATE_FILE}" 2>/dev/null | awk '{print $2}' || true)"
[[ "${current:-1}" == "${want}" ]] && exit 0

# shellcheck disable=SC2016  # $shop_backend_ready is an nginx variable, written literally
printf '# Managed by shop-upstream-check: 1 = proxy /api/ to the backend, 0 = answer 503.\nset $shop_backend_ready %s;\n' \
    "${want}" > "${STATE_FILE}"
if command -v restorecon >/dev/null; then restorecon "${STATE_FILE}" || true; fi
if ! out="$(nginx -t 2>&1)"; then
    logger -t shop-upstream-check "nginx configuration test failed, not reloading: ${out}"
    exit 1
fi
systemctl reload nginx
if (( want == 1 )); then
    logger -t shop-upstream-check "backend READY (${URL}): back in rotation"
else
    logger -t shop-upstream-check "backend NOT READY (${URL}): out of rotation, /api answers 503"
fi
