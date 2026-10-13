#!/usr/bin/env bash
# Deletes orders placed by the load generator (note = 'k6') that are older than N days, with their items,
# history and gateway payments, then recomputes product sales counts and coupon usage.
# Usage: ENV_FILE=/etc/shop/db.env shop-load-cleanup [days]     (days: default LOAD_CLEANUP_DAYS or 2; 0 = all)
set -euo pipefail
ENV_FILE="${ENV_FILE:-/etc/shop/db.env}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
DAYS="${1:-${LOAD_CLEANUP_DAYS:-2}}"
[[ "${DAYS}" =~ ^[0-9]+$ ]] || { echo "days must be a number"; exit 1; }
CODES="$(mktemp)"
chmod 644 "${CODES}"
trap 'rm -f "${CODES}"' EXIT

runuser -u postgres -- psql -d "${SHOP_DB_NAME}" -v ON_ERROR_STOP=1 -Atq > "${CODES}" <<SQL
BEGIN;
CREATE TEMP TABLE gone ON COMMIT DROP AS
    SELECT id, code FROM orders WHERE note = 'k6' AND created_at < now() - make_interval(days => ${DAYS});
DELETE FROM order_history WHERE order_id IN (SELECT id FROM gone);
DELETE FROM order_items WHERE order_id IN (SELECT id FROM gone);
DELETE FROM orders WHERE id IN (SELECT id FROM gone);
UPDATE products p SET sold_count = COALESCE((
    SELECT sum(i.quantity) FROM order_items i JOIN orders o ON o.id = i.order_id
    WHERE i.product_id = p.id AND o.status NOT IN ('CANCELLED', 'PAYMENT_FAILED')), 0);
UPDATE coupons c SET used_count = (
    SELECT count(*) FROM orders o WHERE o.coupon_code = c.code AND o.status NOT IN ('CANCELLED', 'PAYMENT_FAILED'));
SELECT code FROM gone;
COMMIT;
SQL

deleted="$(grep -c . "${CODES}" || true)"
runuser -u postgres -- psql -d "${PAYMENT_DB_NAME}" -v ON_ERROR_STOP=1 -q <<SQL
CREATE TEMP TABLE gone (code varchar(30));
\copy gone FROM '${CODES}'
DELETE FROM payments p USING gone g WHERE p.order_code = g.code;
SQL
echo "$(date -Is) removed ${deleted} load-test orders older than ${DAYS} day(s)"
