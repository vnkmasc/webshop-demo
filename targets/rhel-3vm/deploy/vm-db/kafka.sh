#!/usr/bin/env bash
# Order event queue on the database VM: Apache Kafka, single node in KRaft mode (no ZooKeeper), as the systemd
# service "kafka". Only the application VM may reach the broker port. Idempotent; run by install.sh when
# KAFKA_ENABLED=true, or on its own.
# Usage: sudo ./kafka.sh [/etc/shop/db.env]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../common/lib.sh
source "${HERE}/../common/lib.sh"
require_root
require_rhel9

ENV_FILE="${1:-/etc/shop/db.env}"
load_env "${ENV_FILE}" BACKEND_HOST KAFKA_ADVERTISED_HOST

KAFKA_VERSION="${KAFKA_VERSION:-4.3.1}"
KAFKA_SCALA="${KAFKA_SCALA:-2.13}"
# SHA-512 of the pinned release; set KAFKA_SHA512 too when changing KAFKA_VERSION.
KAFKA_SHA512="${KAFKA_SHA512:-c7d7b2318cb51aa0c61d3246a51c349210073c5c9b754947ef965a439f2f939e8600f204e134a75ac31faf3829c9370960ef7c6a9886c8a1dbf0339a21f4c54c}"
KAFKA_PORT="${KAFKA_PORT:-9092}"
KAFKA_HEAP="${KAFKA_HEAP:-512m}"
KAFKA_RETENTION_HOURS="${KAFKA_RETENTION_HOURS:-72}"
NAME="kafka_${KAFKA_SCALA}-${KAFKA_VERSION}"
HOME_DIR=/opt/kafka

log "Installing Java 21 for Kafka ${KAFKA_VERSION}"
pkg_install java-21-openjdk-headless >/dev/null

getent group kafka >/dev/null || groupadd --system kafka
getent passwd kafka >/dev/null || useradd --system -g kafka -d /var/lib/kafka -s /sbin/nologin kafka
install -d -o kafka -g kafka -m 750 /var/lib/kafka /var/lib/kafka/data /var/log/kafka
install -d -m 755 "${HOME_DIR}" /etc/kafka

if [[ ! -x "${HOME_DIR}/${NAME}/bin/kafka-server-start.sh" ]]; then
    tgz="$(mktemp -d)/${NAME}.tgz"
    if [[ -n "${KAFKA_TGZ:-}" ]]; then
        cp "${KAFKA_TGZ}" "${tgz}"
    else
        log "Downloading ${NAME}.tgz"
        curl -fsSL -o "${tgz}" "https://downloads.apache.org/kafka/${KAFKA_VERSION}/${NAME}.tgz" \
            || curl -fsSL -o "${tgz}" "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${NAME}.tgz"
    fi
    echo "${KAFKA_SHA512}  ${tgz}" | sha512sum -c --quiet - || die "Checksum mismatch for ${NAME}.tgz"
    tar -C "${HOME_DIR}" -xzf "${tgz}"
    rm -rf "$(dirname "${tgz}")"
fi
ln -sfn "${HOME_DIR}/${NAME}" "${HOME_DIR}/current"

log "Configuring the broker (advertised ${KAFKA_ADVERTISED_HOST}:${KAFKA_PORT})"
cat > /etc/kafka/server.properties <<CONF
# Managed by deploy/vm-db/kafka.sh: single node acting as broker and controller.
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@127.0.0.1:9093
listeners=PLAINTEXT://0.0.0.0:${KAFKA_PORT},CONTROLLER://127.0.0.1:9093
advertised.listeners=PLAINTEXT://${KAFKA_ADVERTISED_HOST}:${KAFKA_PORT}
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT
listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
log.dirs=/var/lib/kafka/data
num.partitions=3
default.replication.factor=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
share.coordinator.state.topic.replication.factor=1
share.coordinator.state.topic.min.isr=1
# Topics are created by the application (orders, 3 partitions); no accidental topics from typos.
auto.create.topics.enable=false
group.initial.rebalance.delay.ms=0
log.retention.hours=${KAFKA_RETENTION_HOURS}
CONF

if [[ ! -f /var/lib/kafka/data/meta.properties ]]; then
    log "Formatting the KRaft storage"
    runuser -u kafka -- "${HOME_DIR}/current/bin/kafka-storage.sh" format \
        -t "$("${HOME_DIR}/current/bin/kafka-storage.sh" random-uuid)" -c /etc/kafka/server.properties
fi

cat > /etc/systemd/system/kafka.service <<UNIT
[Unit]
Description=Apache Kafka ${KAFKA_VERSION} (order event queue, KRaft single node)
After=network-online.target
Wants=network-online.target

[Service]
User=kafka
Group=kafka
Environment=KAFKA_HEAP_OPTS=-Xms${KAFKA_HEAP} -Xmx${KAFKA_HEAP}
Environment=LOG_DIR=/var/log/kafka
ExecStart=${HOME_DIR}/current/bin/kafka-server-start.sh /etc/kafka/server.properties
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable kafka >/dev/null
systemctl restart kafka

log "Firewall: ${KAFKA_PORT} only from ${BACKEND_HOST}"
ensure_firewalld
fw_allow_from "${BACKEND_HOST}" "${KAFKA_PORT}"

for _ in $(seq 1 30); do
    "${HOME_DIR}/current/bin/kafka-broker-api-versions.sh" --bootstrap-server "127.0.0.1:${KAFKA_PORT}" >/dev/null 2>&1 \
        && { log "Kafka is up on ${KAFKA_ADVERTISED_HOST}:${KAFKA_PORT}"; exit 0; }
    sleep 2
done
die "Kafka did not answer on port ${KAFKA_PORT}; see journalctl -u kafka and /var/log/kafka/server.log"
