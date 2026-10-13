#!/usr/bin/env bash
# Daily pg_dump (custom format) of the shop and payment databases; keeps the newest BACKUP_KEEP per database.
set -euo pipefail
ENV_FILE="${ENV_FILE:-/etc/shop/db.env}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
BACKUP_DIR="${BACKUP_DIR:-/var/lib/pgsql/backups/shop}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
for db in "${SHOP_DB_NAME}" "${PAYMENT_DB_NAME}"; do
    file="${BACKUP_DIR}/${db}-$(date +%Y%m%d-%H%M%S).dump"
    runuser -u postgres -- pg_dump -Fc "${db}" > "${file}"
    echo "$(date -Is) backup written: ${file} ($(du -h "${file}" | cut -f1))"
    # shellcheck disable=SC2012
    ls -1t "${BACKUP_DIR}/${db}"-*.dump | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f
done
# Restore: runuser -u postgres -- pg_restore --clean --if-exists -d <db> <file>
