#!/usr/bin/env bash
# Runs the k6 load profile.
#   ./run.sh http://shop.example.com smoke
#   ./run.sh http://shop.example.com steady 10 2h      # 10 virtual users for 2 hours
#   ./run.sh http://shop.example.com spike 10          # ramps to 30 users and back
# ADMIN_PASSWORD must match APP_ADMIN_PASSWORD of the backend (the admin persona processes orders and restocks).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v k6 >/dev/null || { echo "k6 is required: https://grafana.com/docs/k6/latest/set-up/install-k6/"; exit 2; }
export BASE_URL="${1:-http://localhost}"
export PROFILE="${2:-smoke}"
export VUS="${3:-10}"
export DURATION="${4:-30m}"
exec k6 run --summary-trend-stats "avg,p(90),p(95),max" "${HERE}/shop.js"
