#!/usr/bin/env bash
# Shared helpers for the VM install/deploy scripts (RHEL 9 and compatible: Rocky / AlmaLinux 9).

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Run as root (sudo $0 ...)"
}

# Checks the OS is RHEL 9 family; dnf must be able to reach its repositories (RHEL needs an active subscription).
require_rhel9() {
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID}:${VERSION_ID%%.*}" in
        rhel:9 | rocky:9 | almalinux:9 | centos:9) ;;
        *) die "Unsupported OS ${PRETTY_NAME:-unknown}; these scripts target RHEL 9" ;;
    esac
    if [[ "${ID}" == "rhel" ]] && command -v subscription-manager >/dev/null \
        && ! subscription-manager status >/dev/null 2>&1; then
        warn "RHEL subscription is not active: dnf may fail to download packages (subscription-manager register)"
    fi
}

# load_env FILE VAR...: sources an env file and checks that the listed variables are set.
load_env() {
    local file="$1"; shift
    [[ -f "${file}" ]] || die "Missing ${file}. Copy the .env.example next to this script, fill it in and retry."
    set -a
    # shellcheck disable=SC1090
    source "${file}"
    set +a
    local v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || die "${v} must be set in ${file}"
    done
}

# Refuses obviously unchanged example secrets.
check_secret() {
    local name="$1" value="$2"
    if [[ "${value}" == change-me* ]]; then
        die "${name} still has the example value; set a real secret"
    fi
}

pkg_install() {
    dnf install -y "$@"
}

# ------------------------------------------------------------------ firewalld

ensure_firewalld() {
    pkg_install firewalld >/dev/null
    systemctl enable --now firewalld >/dev/null
    firewall-cmd --permanent --add-service=ssh >/dev/null
}

# fw_allow_from SOURCE PORT: only SOURCE (IP or CIDR) may reach PORT/tcp. Idempotent.
fw_allow_from() {
    local rule="rule family=\"ipv4\" source address=\"$1\" port port=\"$2\" protocol=\"tcp\" accept"
    firewall-cmd --permanent --query-rich-rule="${rule}" >/dev/null 2>&1 \
        || firewall-cmd --permanent --add-rich-rule="${rule}" >/dev/null
}

# fw_allow_service NAME: open a service (http, https...) to everyone.
fw_allow_service() {
    firewall-cmd --permanent --add-service="$1" >/dev/null
}

fw_apply() {
    firewall-cmd --reload >/dev/null
    firewall-cmd --list-all
}
