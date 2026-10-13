#!/usr/bin/env bash
# Publishes a front-end build as a new release directory and switches the "current" symlink atomically.
# Usage: sudo ./deploy.sh path/to/frontend/dist
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../common/lib.sh
source "${HERE}/../common/lib.sh"
require_root

DIST="${1:?usage: deploy.sh path/to/frontend/dist}"
[[ -f "${DIST}/index.html" ]] || die "${DIST}/index.html not found - is this a front-end build?"
RELEASES=/var/www/shop/releases
KEEP="${KEEP:-5}"
release="${RELEASES}/$(date +%Y%m%d%H%M%S)"

install -d "${release}"
cp -r "${DIST}/." "${release}/"
chmod -R a+rX "${release}"
if command -v restorecon >/dev/null; then restorecon -R "${release}"; fi
previous="$(readlink -f /var/www/shop/current || true)"
ln -sfn "${release}" /var/www/shop/current.new
mv -T /var/www/shop/current.new /var/www/shop/current

if ! nginx -t; then
    [[ -n "${previous}" ]] && ln -sfn "${previous}" /var/www/shop/current
    die "nginx configuration test failed; previous release restored"
fi
systemctl reload nginx
log "Front end published: ${release}"

# Keep the newest KEEP releases (rollback: point "current" to an older one and reload nginx).
# shellcheck disable=SC2012
ls -1dt "${RELEASES}"/*/ | tail -n +"$((KEEP + 1))" | xargs -r rm -rf
