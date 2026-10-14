#!/usr/bin/env bash
# Writes the env files of the containers from /etc/shop/app.env:
#   /etc/shop/payment.env (shop-payment)   /etc/shop/risk.env (shop-risk)
# app.env is a shell-style file (quoted values); docker --env-file takes values literally,
# so only the variables the gateway needs are exported here, unquoted.
set -euo pipefail
SRC="${1:-/etc/shop/app.env}"
DST="${2:-/etc/shop/payment.env}"
RISK_DST="${3:-/etc/shop/risk.env}"
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

{
    echo "# Generated from ${SRC} by shop-container-env - edit app.env instead, then run shop-container-env"
    for v in RISK_API_KEY APP_RELEASE_VERSION APP_RELEASE_STAGE; do
        if [[ -n "${!v:-}" ]]; then
            printf '%s=%s\n' "${v}" "${!v}"
        fi
    done
    # Optional Python auto-instrumentation hook of a monitoring agent (package from RISK_EXTRA_PIP_PACKAGES).
    if [[ -n "${RISK_AUTOWRAPT_BOOTSTRAP:-}" ]]; then
        printf 'AUTOWRAPT_BOOTSTRAP=%s\n' "${RISK_AUTOWRAPT_BOOTSTRAP}"
    fi
} > "${RISK_DST}.tmp"
mv "${RISK_DST}.tmp" "${RISK_DST}"
chmod 600 "${RISK_DST}"
