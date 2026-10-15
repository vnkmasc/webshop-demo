#!/usr/bin/env bash
# shellcheck disable=SC2015  # "ok" always succeeds, so A && ok || bad is safe here
# End-to-end check of a deployed shop with sample data (APP_SEED_ENABLED=true).
# Usage: ./smoke/smoke-test.sh http://shop.example.com [admin-password]
# Needs curl and jq. Creates a few real orders (guest COD, card approved, card declined) and one customer account.
set -uo pipefail
BASE="${1:?usage: smoke-test.sh <base-url> [admin-password]}"
ADMIN_PASSWORD="${2:-SaiBuoc@2026}"
API="${BASE%/}/api"
PASS=0
FAIL=0
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# req METHOD PATH [JSON] [TOKEN] -> prints status; body in $TMP
req() {
    local args=(-s -o "${TMP}" -w '%{http_code}' -X "$1" "${API}$2" -H 'Content-Type: application/json')
    [[ -n "${3:-}" ]] && args+=(-d "$3")
    [[ -n "${4:-}" ]] && args+=(-H "Authorization: Bearer $4")
    curl "${args[@]}"
}
expect() { # expect LABEL EXPECTED_STATUS ACTUAL_STATUS
    if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (expected $2, got $3: $(head -c 200 "${TMP}"))"; fi
}
jqr() { jq -r "$1" "${TMP}"; }

section "1. Storefront"
expect "home page HTML" 200 "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/")"
expect "product image" 200 "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/images/shoes/running-do.svg")"
expect "GET /home" 200 "$(req GET /home)"
[[ "$(jqr '.data.bestsellers | length')" -gt 0 ]] && ok "home has bestsellers" || bad "home has bestsellers"
expect "GET /products?category=sneaker&sort=price_asc" 200 "$(req GET '/products?category=sneaker&sort=price_asc')"
expect "search q=chay bo" 200 "$(req GET '/products?q=chay%20bo')"
[[ "$(jqr '.data.totalElements')" -gt 0 ]] && ok "search without accents finds products" || bad "search without accents finds products"
expect "GET /products (all, filter size 42)" 200 "$(req GET '/products?size=42&pageSize=60')"
SLUG="$(jq -r '[.data.content[] | select(.inStock)][0].slug' "${TMP}")"
expect "GET /products/${SLUG}" 200 "$(req GET "/products/${SLUG}")"
VARIANT="$(jq -r '[.data.variants[] | select(.stock >= 3)][0].id' "${TMP}")"
STOCK_BEFORE="$(jq -r "[.data.variants[] | select(.id == ${VARIANT})][0].stock" "${TMP}")"
expect "GET /catalog/facets" 200 "$(req GET /catalog/facets)"

section "2. Cart and coupons"
expect "quote" 200 "$(req POST /cart/quote "{\"items\":[{\"variantId\":${VARIANT},\"quantity\":1}]}")"
SUBTOTAL="$(jqr '.data.subtotal')"
expect "quote with CHAOBAN" 200 "$(req POST /cart/quote "{\"items\":[{\"variantId\":${VARIANT},\"quantity\":2}],\"couponCode\":\"chaoban\"}")"
[[ "$(jqr '.data.couponApplied')" == true || "${SUBTOTAL}" -lt 250000 ]] && ok "coupon applied" || bad "coupon applied ($(jqr '.data.couponMessage'))"
expect "quote with expired coupon" 200 "$(req POST /cart/quote "{\"items\":[{\"variantId\":${VARIANT},\"quantity\":1}],\"couponCode\":\"HE2025\"}")"
[[ "$(jqr '.data.couponApplied')" == false ]] && ok "expired coupon rejected" || bad "expired coupon rejected"
expect "quote 999 pairs" 400 "$(req POST /cart/quote "{\"items\":[{\"variantId\":${VARIANT},\"quantity\":999}]}")"

CUSTOMER='"customer":{"name":"Khách Kiểm Tra","phone":"0987654321","address":"1 Lê Lợi","province":"Hà Nội","note":"smoke test"}'
section "3. Checkout"
expect "guest COD order" 200 "$(req POST /orders "{\"items\":[{\"variantId\":${VARIANT},\"quantity\":1}],${CUSTOMER},\"paymentMethod\":\"COD\"}")"
COD_CODE="$(jqr '.data.code')"
[[ "$(jqr '.data.status')" == PENDING ]] && ok "COD order is PENDING ($COD_CODE)" || bad "COD order status"
expect "stock decreased" 200 "$(req GET "/products/${SLUG}")"
STOCK_AFTER="$(jq -r "[.data.variants[] | select(.id == ${VARIANT})][0].stock" "${TMP}")"
[[ "${STOCK_AFTER}" -eq $((STOCK_BEFORE - 1)) ]] && ok "stock ${STOCK_BEFORE} -> ${STOCK_AFTER}" || bad "stock ${STOCK_BEFORE} -> ${STOCK_AFTER}"
CARD_OK='"card":{"number":"4111 1111 1111 1111","holder":"KHACH KIEM TRA","expiry":"12/30","cvv":"123"}'
expect "card order approved" 200 "$(req POST /orders "{\"items\":[{\"variantId\":${VARIANT},\"quantity\":1}],${CUSTOMER},\"paymentMethod\":\"CARD\",${CARD_OK}}")"
CARD_CODE="$(jqr '.data.code')"
[[ "$(jqr '.data.paymentStatus')" == PAID ]] && ok "card order PAID ($CARD_CODE, $(jqr '.data.paymentRef'))" || bad "card order PAID"
CARD_BAD='"card":{"number":"4000 0000 0000 0002","holder":"KHACH KIEM TRA","expiry":"12/30","cvv":"123"}'
expect "declined card -> 422" 422 "$(req POST /orders "{\"items\":[{\"variantId\":${VARIANT},\"quantity\":1}],${CUSTOMER},\"paymentMethod\":\"CARD\",${CARD_BAD}}")"
[[ "$(jqr '.errorCode')" == PAYMENT_DECLINED ]] && ok "errorCode PAYMENT_DECLINED" || bad "errorCode PAYMENT_DECLINED"
expect "stock restored after decline" 200 "$(req GET "/products/${SLUG}")"
[[ "$(jq -r "[.data.variants[] | select(.id == ${VARIANT})][0].stock" "${TMP}")" -eq $((STOCK_BEFORE - 2)) ]] && ok "stock correct after decline" || bad "stock correct after decline"
expect "order lookup by code + phone" 200 "$(req GET "/orders/lookup?code=${COD_CODE}&phone=0987654321")"
expect "order lookup wrong phone" 404 "$(req GET "/orders/lookup?code=${COD_CODE}&phone=0900000000")"

section "4. Customer account"
EMAIL="smoke$(date +%s)@example.com"
expect "register" 200 "$(req POST /auth/register "{\"email\":\"${EMAIL}\",\"password\":\"Matkhau123\",\"fullName\":\"Smoke Test\"}")"
expect "login demo customer" 200 "$(req POST /auth/login '{"email":"khach@saibuoc.vn","password":"SaiBuoc@2026"}')"
CT="$(jqr '.data.accessToken')"
expect "my orders" 200 "$(req GET /account/orders '' "${CT}")"
[[ "$(jqr '.data | length')" -gt 0 ]] && ok "demo customer has order history" || bad "demo customer has order history"
expect "customer cannot open admin API" 403 "$(req GET /admin/dashboard '' "${CT}")"
expect "no token -> 401 on account" 401 "$(req GET /account/orders)"
expect "wrong password -> 401" 401 "$(req POST /auth/login '{"email":"khach@saibuoc.vn","password":"sai-mat-khau"}')"

section "5. Admin"
expect "admin login" 200 "$(req POST /auth/login "{\"email\":\"admin@saibuoc.vn\",\"password\":\"${ADMIN_PASSWORD}\"}")"
AT="$(jqr '.data.accessToken')"
for d in 1 7 30 90; do expect "dashboard ${d} days" 200 "$(req GET "/admin/dashboard?days=${d}" '' "${AT}")"; done
[[ "$(jqr '.data.kpis.orders')" -gt 100 ]] && ok "90-day dashboard has orders ($(jqr '.data.kpis.orders'))" || bad "90-day dashboard has orders"
expect "admin products (low stock)" 200 "$(req GET '/admin/products?lowStock=true' '' "${AT}")"
expect "admin orders PENDING" 200 "$(req GET '/admin/orders?status=PENDING&q=098765' '' "${AT}")"
expect "admin customers" 200 "$(req GET '/admin/customers?q=nguyen' '' "${AT}")"
expect "admin coupons" 200 "$(req GET /admin/coupons '' "${AT}")"
# Order queue: the warehouse consumer takes the order over within seconds (skipped when no queue is configured).
for _ in $(seq 1 15); do
    req GET "/admin/orders/${COD_CODE}" '' "${AT}" >/dev/null
    FULFILLMENT="$(jqr '.data.order.fulfillmentStatus')"
    [[ "${FULFILLMENT}" == QUEUED ]] || break
    sleep 1
done
case "${FULFILLMENT}" in
    RECEIVED) ok "order queue: warehouse received ${COD_CODE}" ;;
    null | "") ok "order queue not configured (skipped)" ;;
    *) bad "order queue: ${COD_CODE} is ${FULFILLMENT}" ;;
esac
expect "confirm COD order" 200 "$(req POST "/admin/orders/${COD_CODE}/status" '{"status":"CONFIRMED"}' "${AT}")"
expect "ship COD order" 200 "$(req POST "/admin/orders/${COD_CODE}/status" '{"status":"SHIPPING"}' "${AT}")"
expect "deliver COD order" 200 "$(req POST "/admin/orders/${COD_CODE}/status" '{"status":"DELIVERED"}' "${AT}")"
[[ "$(jqr '.data.order.paymentStatus')" == PAID ]] && ok "COD paid on delivery" || bad "COD paid on delivery"
expect "invalid transition -> 409" 409 "$(req POST "/admin/orders/${COD_CODE}/status" '{"status":"CONFIRMED"}' "${AT}")"
expect "cancel card order (refund)" 200 "$(req POST "/admin/orders/${CARD_CODE}/status" '{"status":"CANCELLED","note":"smoke test"}' "${AT}")"
[[ "$(jqr '.data.order.paymentStatus')" == REFUNDED ]] && ok "card order refunded" || bad "card order refunded"
expect "payment gateway settings" 200 "$(req GET /admin/payment-gateway '' "${AT}")"
expect "simulation status" 200 "$(req GET /admin/simulation '' "${AT}")"

section "6. Internal endpoints are not public"
expect "/actuator/health via nginx -> 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/actuator/health")"
HOST="$(echo "${BASE}" | sed -E 's#^https?://([^/:]+).*#\1#')"
for port in 8080 8081 8090 5432; do
    if timeout 3 bash -c "</dev/tcp/${HOST}/${port}" 2>/dev/null; then bad "port ${port} reachable on ${HOST}"; else ok "port ${port} not reachable on ${HOST}"; fi
done

printf '\n\033[1mResult: %d passed, %d failed\033[0m\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
