#!/usr/bin/env bash
# Writes /etc/shop/payment.env (docker --env-file) for the payment container from /etc/shop/app.env.
# app.env is a shell-style file (quoted values); docker --env-file takes values literally,
# so only the variables the gateway needs are exported here, unquoted.
set -euo pipefail
SRC="${1:-/etc/shop/app.env}"
DST="${2:-/etc/shop/payment.env}"
set -a
# shellcheck disable=SC1090
source "${SRC}"
set +a
umask 077
{
    echo "# Generated from ${SRC} by shop-payment-env - edit app.env instead, then run shop-payment-env"
    for v in DB_HOST DB_PORT PAYMENT_DB_NAME PAYMENT_DB_USER PAYMENT_DB_PASSWORD PAYMENT_API_KEY \
             APP_RELEASE_VERSION APP_RELEASE_STAGE; do
        if [[ -n "${!v:-}" ]]; then
            printf '%s=%s\n' "${v}" "${!v}"
        fi
    done
    printf 'JAVA_OPTS_APPEND=%s\n' "${PAYMENT_JAVA_OPTS:--Xms128m -Xmx384m -Duser.timezone=UTC}"
} > "${DST}.tmp"
mv "${DST}.tmp" "${DST}"
chmod 600 "${DST}"
