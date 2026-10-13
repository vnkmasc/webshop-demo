#!/usr/bin/env bash
# Database VM (RHEL 9): PostgreSQL 16 with the shop and payment databases. Idempotent.
# Usage: sudo ./install.sh [/etc/shop/db.env]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../common/lib.sh
source "${HERE}/../common/lib.sh"
require_root
require_rhel9

ENV_FILE="${1:-/etc/shop/db.env}"
load_env "${ENV_FILE}" BACKEND_HOST SHOP_DB_NAME SHOP_DB_USER SHOP_DB_PASSWORD PAYMENT_DB_NAME PAYMENT_DB_USER PAYMENT_DB_PASSWORD
check_secret SHOP_DB_PASSWORD "${SHOP_DB_PASSWORD}"
check_secret PAYMENT_DB_PASSWORD "${PAYMENT_DB_PASSWORD}"
if [[ "${ENV_FILE}" != /etc/shop/db.env ]]; then
    install -D -m 600 "${ENV_FILE}" /etc/shop/db.env
    ENV_FILE=/etc/shop/db.env
fi
chmod 600 "${ENV_FILE}"

log "Installing PostgreSQL 16 (AppStream module)"
dnf -y module reset postgresql >/dev/null
dnf -y module enable postgresql:16 >/dev/null
pkg_install postgresql-server postgresql-contrib cronie

PGDATA=/var/lib/pgsql/data
if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
    postgresql-setup --initdb
fi

log "Configuring PostgreSQL"
install -d -o postgres -g postgres -m 700 "${PGDATA}/conf.d"
grep -q "^include_dir = 'conf.d'" "${PGDATA}/postgresql.conf" \
    || echo "include_dir = 'conf.d'" >> "${PGDATA}/postgresql.conf"
cat > "${PGDATA}/conf.d/shop.conf" <<CONF
# Managed by deploy/vm-db/install.sh
listen_addresses = '*'
timezone = 'UTC'
log_timezone = 'UTC'
max_connections = 150
shared_buffers = '1GB'
effective_cache_size = '4GB'
work_mem = '8MB'
maintenance_work_mem = '256MB'
# Statements slower than 1s are logged; per-statement statistics for query analysis.
log_min_duration_statement = 1000
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
password_encryption = scram-sha-256
CONF
chown postgres:postgres "${PGDATA}/conf.d/shop.conf"

# pg_hba: only the application VM may connect over the network (managed block, rewritten each run).
HBA="${PGDATA}/pg_hba.conf"
sed -i '/# BEGIN shop/,/# END shop/d' "${HBA}"
cat >> "${HBA}" <<HBA
# BEGIN shop
host    ${SHOP_DB_NAME}       ${SHOP_DB_USER}       ${BACKEND_HOST}/32    scram-sha-256
host    ${PAYMENT_DB_NAME}    ${PAYMENT_DB_USER}    ${BACKEND_HOST}/32    scram-sha-256
# END shop
HBA

systemctl enable postgresql >/dev/null
systemctl restart postgresql

create_db() {
    local name="$1" user="$2" password="$3"
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${user}') THEN
      CREATE ROLE "${user}" LOGIN PASSWORD '${password}';
   ELSE
      ALTER ROLE "${user}" WITH LOGIN PASSWORD '${password}';
   END IF;
END
\$\$;
SQL
    if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${name}'" | grep -q 1; then
        runuser -u postgres -- createdb -O "${user}" -E UTF8 "${name}"
    fi
    runuser -u postgres -- psql -q -d "${name}" -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'
}

log "Creating databases ${SHOP_DB_NAME} and ${PAYMENT_DB_NAME}"
create_db "${SHOP_DB_NAME}" "${SHOP_DB_USER}" "${SHOP_DB_PASSWORD}"
create_db "${PAYMENT_DB_NAME}" "${PAYMENT_DB_USER}" "${PAYMENT_DB_PASSWORD}"
# Tables are created by the services themselves (Flyway) on first start.

log "Installing daily backup (02:30)"
install -m 750 "${HERE}/backup.sh" /usr/local/bin/shop-db-backup
cat > /etc/cron.d/shop-db-backup <<CRON
30 2 * * * root ENV_FILE=${ENV_FILE} /usr/local/bin/shop-db-backup >> /var/log/shop-db-backup.log 2>&1
CRON
systemctl enable --now crond >/dev/null

if [[ -n "${LOAD_CLEANUP_DAYS:-}" ]]; then
    log "Installing nightly clean-up of load-test orders older than ${LOAD_CLEANUP_DAYS} days (03:00)"
    install -m 750 "${HERE}/cleanup-load-orders.sh" /usr/local/bin/shop-load-cleanup
    cat > /etc/cron.d/shop-load-cleanup <<CRON
0 3 * * * root ENV_FILE=${ENV_FILE} /usr/local/bin/shop-load-cleanup >> /var/log/shop-load-cleanup.log 2>&1
CRON
else
    rm -f /etc/cron.d/shop-load-cleanup
fi

log "Firewall: SSH from anywhere, 5432 only from ${BACKEND_HOST}"
ensure_firewalld
fw_allow_from "${BACKEND_HOST}" 5432
fw_apply

systemctl is-active --quiet postgresql || die "postgresql is not running"
log "Database VM ready. Next: install the application VM."
