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

env_value() {
    awk -v key="$1" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                value = line
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
                sub(/[[:space:]]+#.*$/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) {
                    value = substr(value, 2, length(value) - 2)
                }
            }
        }
        END { print value }
    ' "${ENV_FILE}"
}

OCSERV_CONF_DIR=${OCSERV_CONF_DIR:-$(env_value OCSERV_CONF_DIR)}
OCSERV_CONF_DIR="${OCSERV_CONF_DIR:-/etc/ocserv}"
OUTPUT_FILE=${OCSERV_CONF_OUTPUT:-"${OCSERV_CONF_DIR}/ocserv.conf"}

DOMAIN=${DOMAIN:-}
if [ -z "${DOMAIN}" ]; then
    DOMAIN=$(env_value DOMAIN)
fi
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-$(env_value OCSERV_ENABLE_COMPRESSION)}
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-false}  # default: keep in sync with .env.example
OCSERV_NO_UDP=${OCSERV_NO_UDP:-$(env_value OCSERV_NO_UDP)}
OCSERV_NO_UDP=${OCSERV_NO_UDP:-false}  # default: keep in sync with .env.example
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-$(env_value OCSERV_MAX_CLIENTS)}
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-32}  # default: keep in sync with .env.example

[ -n "${DOMAIN:-}" ] || fail "DOMAIN is empty in ${ENV_FILE}"

validate_bool OCSERV_ENABLE_COMPRESSION "${OCSERV_ENABLE_COMPRESSION}"
validate_bool OCSERV_NO_UDP "${OCSERV_NO_UDP}"

case "${OCSERV_MAX_CLIENTS}" in
    ''|*[!0-9]*)
        fail "OCSERV_MAX_CLIENTS must be a positive integer: ${OCSERV_MAX_CLIENTS}"
        ;;
esac
[ "${OCSERV_MAX_CLIENTS}" -ge 1 ] || fail "OCSERV_MAX_CLIENTS must be at least 1"

validate_fqdn DOMAIN "${DOMAIN}"

# Reject the placeholder value from .env.example
case "${DOMAIN}" in
    your.domain.com)
        fail "DOMAIN is still set to the placeholder value 'your.domain.com'"
        ;;
esac

# Validate TLS certificate paths
TLS_CERT_FILE=${TLS_CERT_FILE:-$(env_value TLS_CERT_FILE)}
TLS_KEY_FILE=${TLS_KEY_FILE:-$(env_value TLS_KEY_FILE)}
[ -n "${TLS_CERT_FILE}" ] || fail "TLS_CERT_FILE is empty in ${ENV_FILE}"
[ -n "${TLS_KEY_FILE}" ] || fail "TLS_KEY_FILE is empty in ${ENV_FILE}"

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
