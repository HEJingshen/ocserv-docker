#!/bin/sh
set -eu

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=scripts/common.sh disable=SC1091
. "${SCRIPT_DIR}/common.sh"

ENV_FILE=${ENV_FILE:-"${PROJECT_ROOT}/.env"}
TEMPLATE_FILE=${OCSERV_CONF_TEMPLATE:-"${PROJECT_ROOT}/config/ocserv.conf.template"}

[ -f "${ENV_FILE}" ] || fail "env file not found: ${ENV_FILE}. Copy .env.example to .env first."
[ -f "${TEMPLATE_FILE}" ] || fail "template file not found: ${TEMPLATE_FILE}"

OCSERV_CONF_DIR=${OCSERV_CONF_DIR:-$(env_file_value "${ENV_FILE}" OCSERV_CONF_DIR)}
OCSERV_CONF_DIR="${OCSERV_CONF_DIR:-/etc/ocserv}"
OUTPUT_FILE=${OCSERV_CONF_OUTPUT:-"${OCSERV_CONF_DIR}/ocserv.conf"}

DOMAIN=${DOMAIN:-$(env_file_value "${ENV_FILE}" DOMAIN)}
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-$(env_file_value "${ENV_FILE}" OCSERV_ENABLE_COMPRESSION)}
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-false}  # default: keep in sync with .env.example
OCSERV_NO_UDP=${OCSERV_NO_UDP:-$(env_file_value "${ENV_FILE}" OCSERV_NO_UDP)}
OCSERV_NO_UDP=${OCSERV_NO_UDP:-false}  # default: keep in sync with .env.example
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-$(env_file_value "${ENV_FILE}" OCSERV_MAX_CLIENTS)}
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-32}  # default: keep in sync with .env.example

validate_domain DOMAIN "${DOMAIN}"

validate_bool OCSERV_ENABLE_COMPRESSION "${OCSERV_ENABLE_COMPRESSION}"
validate_bool OCSERV_NO_UDP "${OCSERV_NO_UDP}"

case "${OCSERV_MAX_CLIENTS}" in
    ''|*[!0-9]*)
        fail "OCSERV_MAX_CLIENTS must be a positive integer: ${OCSERV_MAX_CLIENTS}"
        ;;
esac
[ "${OCSERV_MAX_CLIENTS}" -ge 1 ] || fail "OCSERV_MAX_CLIENTS must be at least 1"

# Validate TLS certificate paths
TLS_CERT_FILE=${TLS_CERT_FILE:-$(env_file_value "${ENV_FILE}" TLS_CERT_FILE)}
TLS_KEY_FILE=${TLS_KEY_FILE:-$(env_file_value "${ENV_FILE}" TLS_KEY_FILE)}
validate_tls_paths "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"

OUTPUT_DIR=$(dirname -- "${OUTPUT_FILE}")
mkdir -p "${OUTPUT_DIR}" 2>/dev/null || fail "cannot create output directory: ${OUTPUT_DIR} (run with sudo)"

TMP_FILE=$(mktemp "${OUTPUT_DIR}/.ocserv.conf.XXXXXX") || fail "failed to create temporary config"
trap 'rm -f "${TMP_FILE}"' EXIT HUP INT TERM

awk -v domain="${DOMAIN}" \
    -v enable_compression="${OCSERV_ENABLE_COMPRESSION}" \
    -v no_udp="${OCSERV_NO_UDP}" \
    -v max_clients="${OCSERV_MAX_CLIENTS}" '
    {
        gsub(/\$\{DOMAIN\}/, domain)
        if ($0 ~ /^[[:space:]]*compression[[:space:]]*=/) {
            print "compression = " enable_compression
            next
        }
        if ($0 ~ /^[[:space:]]*no-udp[[:space:]]*=/) {
            print "no-udp = " no_udp
            next
        }
        if ($0 ~ /^[[:space:]]*max-clients[[:space:]]*=/) {
            sub(/=.*/, "= " max_clients)
        }
        print
    }
' "${TEMPLATE_FILE}" > "${TMP_FILE}"

# shellcheck disable=SC2016
if grep -q '\${DOMAIN}' "${TMP_FILE}"; then
    fail "unrendered DOMAIN placeholder remains in generated config"
fi

chmod 0644 "${TMP_FILE}"

mv "${TMP_FILE}" "${OUTPUT_FILE}"
trap - EXIT HUP INT TERM

printf 'Rendered %s from %s using DOMAIN=%s OCSERV_MAX_CLIENTS=%s OCSERV_ENABLE_COMPRESSION=%s OCSERV_NO_UDP=%s\n' \
    "${OUTPUT_FILE}" "${TEMPLATE_FILE}" "${DOMAIN}" "${OCSERV_MAX_CLIENTS}" "${OCSERV_ENABLE_COMPRESSION}" "${OCSERV_NO_UDP}"
