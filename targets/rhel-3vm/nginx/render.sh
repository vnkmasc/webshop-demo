#!/usr/bin/env bash
# Renders the nginx site config from the templates. Used by the Docker image and by deploy/vm-web.
#   APP_DOMAIN        public domain (e.g. shop.example.com)
#   BACKEND_UPSTREAM  backend host:port (e.g. 10.0.0.12:8080)
#   WEB_ROOT          directory with the React build
#   TEMPLATE_DIR      where the *.conf.template files are (default: next to this script)
#   OUTPUT            rendered file (default: /etc/nginx/conf.d/shop.conf)
# HTTPS is enabled automatically when /etc/nginx/certs/fullchain.pem and privkey.pem exist.
set -euo pipefail

: "${APP_DOMAIN:?APP_DOMAIN is required}"
: "${BACKEND_UPSTREAM:?BACKEND_UPSTREAM is required}"
WEB_ROOT="${WEB_ROOT:-/usr/share/nginx/html}"
TEMPLATE_DIR="${TEMPLATE_DIR:-$(dirname "$0")/templates}"
OUTPUT="${OUTPUT:-/etc/nginx/conf.d/shop.conf}"
CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"

if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
    template="${TEMPLATE_DIR}/https.conf.template"
    echo "render.sh: certificates found, enabling HTTPS for ${APP_DOMAIN}"
else
    template="${TEMPLATE_DIR}/http.conf.template"
    echo "render.sh: no certificates in ${CERT_DIR}, serving HTTP only"
fi

export APP_DOMAIN BACKEND_UPSTREAM WEB_ROOT
# Only our variables are substituted; nginx variables such as $host stay untouched.
# shellcheck disable=SC2016
envsubst '${APP_DOMAIN} ${BACKEND_UPSTREAM} ${WEB_ROOT}' < "${template}" > "${OUTPUT}"
