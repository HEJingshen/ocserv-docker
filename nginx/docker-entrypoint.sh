#!/bin/sh
set -eu

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "$2 not found: $1"
    [ -r "$1" ] || fail "$2 is not readable: $1"
}

require_command() {
    case "$1" in
        */*)
            [ -x "$1" ] || fail "$2 command is not executable: $1"
            ;;
        *)
            command -v "$1" >/dev/null 2>&1 || fail "$2 command not found: $1"
            ;;
    esac
}

TEMPLATE_DIR=${TEMPLATE_DIR:-/etc/nginx/templates}
CONF_DIR=${CONF_DIR:-/etc/nginx/conf.d}
SNIPPET_FILE=${SNIPPET_FILE:-/etc/nginx/snippets/ssl-params.conf}
LETSENCRYPT_LIVE_DIR=${LETSENCRYPT_LIVE_DIR:-/etc/letsencrypt/live}
NGINX_BIN=${NGINX_BIN:-nginx}

[ -n "${DOMAIN:-}" ] || fail "DOMAIN is required"
[ -n "${MONITORING_PORT:-}" ] || fail "MONITORING_PORT is required"
command -v envsubst >/dev/null 2>&1 || fail "envsubst command not found"
require_command "${NGINX_BIN}" "nginx"

case "${DOMAIN}" in
    *[!A-Za-z0-9.-]*)
        fail "DOMAIN contains invalid characters: ${DOMAIN}"
        ;;
    .*|*.|*..*)
        fail "DOMAIN must not start/end with a dot or contain consecutive dots: ${DOMAIN}"
        ;;
esac

DOMAIN_LENGTH=$(printf '%s' "${DOMAIN}" | wc -c | tr -d ' ')
[ "${DOMAIN_LENGTH}" -le 253 ] || fail "DOMAIN is too long: ${DOMAIN}"

OLD_IFS=${IFS}
IFS=.
set -- ${DOMAIN}
IFS=${OLD_IFS}

for LABEL in "$@"; do
    [ -n "${LABEL}" ] || fail "DOMAIN contains an empty label: ${DOMAIN}"

    LABEL_LENGTH=$(printf '%s' "${LABEL}" | wc -c | tr -d ' ')
    [ "${LABEL_LENGTH}" -le 63 ] || fail "DOMAIN label is too long: ${LABEL}"

    case "${LABEL}" in
        -*|*-)
            fail "DOMAIN label must not start or end with a hyphen: ${LABEL}"
            ;;
    esac
done

case "${MONITORING_PORT}" in
    *[!0-9]*)
        fail "MONITORING_PORT must be numeric: ${MONITORING_PORT}"
        ;;
esac

PORT_LENGTH=$(printf '%s' "${MONITORING_PORT}" | wc -c | tr -d ' ')
[ "${PORT_LENGTH}" -le 5 ] || fail "MONITORING_PORT is out of range: ${MONITORING_PORT}"
[ "${MONITORING_PORT}" -ge 1 ] 2>/dev/null || fail "MONITORING_PORT is out of range: ${MONITORING_PORT}"
[ "${MONITORING_PORT}" -le 65535 ] 2>/dev/null || fail "MONITORING_PORT is out of range: ${MONITORING_PORT}"

[ -d "${TEMPLATE_DIR}" ] || fail "template directory not found: ${TEMPLATE_DIR}"
[ -d "${CONF_DIR}" ] || fail "nginx conf directory not found: ${CONF_DIR}"
[ -w "${CONF_DIR}" ] || fail "nginx conf directory is not writable: ${CONF_DIR}"
require_file "${SNIPPET_FILE}" "SSL snippet"

CERT_FILE="${LETSENCRYPT_LIVE_DIR}/${DOMAIN}/fullchain.pem"
KEY_FILE="${LETSENCRYPT_LIVE_DIR}/${DOMAIN}/privkey.pem"
require_file "${CERT_FILE}" "TLS certificate"
require_file "${KEY_FILE}" "TLS private key"

TEMPLATE_COUNT=0
for TEMPLATE in "${TEMPLATE_DIR}"/*.conf.template; do
    [ -f "${TEMPLATE}" ] || continue
    TEMPLATE_COUNT=$((TEMPLATE_COUNT + 1))
done
[ "${TEMPLATE_COUNT}" -gt 0 ] || fail "no nginx templates found in ${TEMPLATE_DIR}"

TMP_FILE=""
trap 'if [ -n "${TMP_FILE}" ]; then rm -f "${TMP_FILE}"; fi' EXIT HUP INT TERM

echo "Generating nginx configuration from templates..."

for TEMPLATE in "${TEMPLATE_DIR}"/*.conf.template; do
    [ -f "${TEMPLATE}" ] || continue

    FILENAME=$(basename "${TEMPLATE}" .template)
    OUTPUT_FILE="${CONF_DIR}/${FILENAME}"
    TMP_FILE=$(mktemp "${CONF_DIR}/.${FILENAME}.XXXXXX") || fail "failed to create temporary config for ${FILENAME}"

    echo "Processing: ${TEMPLATE} -> ${OUTPUT_FILE}"
    envsubst '${DOMAIN} ${MONITORING_PORT}' < "${TEMPLATE}" > "${TMP_FILE}"

    if grep -Eq '\$\{(DOMAIN|MONITORING_PORT)\}' "${TMP_FILE}"; then
        fail "unrendered DOMAIN or MONITORING_PORT placeholder remains in ${OUTPUT_FILE}"
    fi

    chmod 0644 "${TMP_FILE}"
    mv "${TMP_FILE}" "${OUTPUT_FILE}"
    TMP_FILE=""
done

trap - EXIT HUP INT TERM

"${NGINX_BIN}" -t
echo "Nginx configuration generated and validated successfully."

exec "${NGINX_BIN}" -g 'daemon off;'
