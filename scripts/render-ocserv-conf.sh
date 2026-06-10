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
OUTPUT_FILE=${OCSERV_CONF_OUTPUT:-"${PROJECT_ROOT}/config/ocserv.conf"}

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

DOMAIN=${DOMAIN:-}
if [ -z "${DOMAIN}" ]; then
    DOMAIN=$(env_value DOMAIN)
fi
OCSERV_ENABLE_CERT_AUTH=${OCSERV_ENABLE_CERT_AUTH:-$(env_value OCSERV_ENABLE_CERT_AUTH)}
OCSERV_ENABLE_CERT_AUTH=${OCSERV_ENABLE_CERT_AUTH:-false}  # default: keep in sync with .env.example
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-$(env_value OCSERV_ENABLE_COMPRESSION)}
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-false}  # default: keep in sync with .env.example
OCSERV_NO_UDP=${OCSERV_NO_UDP:-$(env_value OCSERV_NO_UDP)}
OCSERV_NO_UDP=${OCSERV_NO_UDP:-false}  # default: keep in sync with .env.example
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-$(env_value OCSERV_MAX_CLIENTS)}
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-32}  # default: keep in sync with .env.example
OCSERV_ENABLE_SAML_AUTH=${OCSERV_ENABLE_SAML_AUTH:-$(env_value OCSERV_ENABLE_SAML_AUTH)}
OCSERV_ENABLE_SAML_AUTH=${OCSERV_ENABLE_SAML_AUTH:-false}  # default: keep in sync with .env.example
OCSERV_SAML_CONFIG_PATH=${OCSERV_SAML_CONFIG_PATH:-$(env_value OCSERV_SAML_CONFIG_PATH)}
OCSERV_SAML_CONFIG_PATH=${OCSERV_SAML_CONFIG_PATH:-/etc/ocserv/saml/config.ini}  # default: keep in sync with .env.example
OCSERV_HOSTNAME=${OCSERV_HOSTNAME:-$(env_value OCSERV_HOSTNAME)}
OCSERV_HOSTNAME=${OCSERV_HOSTNAME:-${DOMAIN}}

[ -n "${DOMAIN:-}" ] || fail "DOMAIN is empty in ${ENV_FILE}"

validate_bool OCSERV_ENABLE_CERT_AUTH "${OCSERV_ENABLE_CERT_AUTH}"
validate_bool OCSERV_ENABLE_COMPRESSION "${OCSERV_ENABLE_COMPRESSION}"
validate_bool OCSERV_NO_UDP "${OCSERV_NO_UDP}"

case "${OCSERV_MAX_CLIENTS}" in
    ''|*[!0-9]*)
        fail "OCSERV_MAX_CLIENTS must be a positive integer: ${OCSERV_MAX_CLIENTS}"
        ;;
esac
[ "${OCSERV_MAX_CLIENTS}" -ge 1 ] || fail "OCSERV_MAX_CLIENTS must be at least 1"

validate_bool OCSERV_ENABLE_SAML_AUTH "${OCSERV_ENABLE_SAML_AUTH}"

case "${OCSERV_SAML_CONFIG_PATH}" in
    ''|*[!A-Za-z0-9./_-]*)
        fail "OCSERV_SAML_CONFIG_PATH contains invalid characters: ${OCSERV_SAML_CONFIG_PATH}"
        ;;
esac

validate_fqdn DOMAIN "${DOMAIN}"

# Reject the placeholder value from .env.example
case "${DOMAIN}" in
    your.domain.com)
        fail "DOMAIN is still set to the placeholder value 'your.domain.com'"
        ;;
esac

validate_fqdn OCSERV_HOSTNAME "${OCSERV_HOSTNAME}"

OUTPUT_DIR=$(dirname -- "${OUTPUT_FILE}")
[ -d "${OUTPUT_DIR}" ] || fail "output directory not found: ${OUTPUT_DIR}"

TMP_FILE=$(mktemp "${OUTPUT_DIR}/.ocserv.conf.XXXXXX") || fail "failed to create temporary config"
trap 'rm -f "${TMP_FILE}"' EXIT HUP INT TERM

awk -v domain="${DOMAIN}" \
    -v hostname="${OCSERV_HOSTNAME}" \
    -v enable_cert_auth="${OCSERV_ENABLE_CERT_AUTH}" \
    -v enable_compression="${OCSERV_ENABLE_COMPRESSION}" \
    -v no_udp="${OCSERV_NO_UDP}" \
    -v max_clients="${OCSERV_MAX_CLIENTS}" \
    -v enable_saml_auth="${OCSERV_ENABLE_SAML_AUTH}" \
    -v saml_config_path="${OCSERV_SAML_CONFIG_PATH}" '
    {
        gsub(/\$\{DOMAIN\}/, domain)
        gsub(/\$\{HOSTNAME\}/, hostname)
        if ($0 ~ /^[[:space:]]*#?[[:space:]]*enable-auth[[:space:]]*=[[:space:]]*"certificate"[[:space:]]*$/) {
            print (enable_cert_auth == "true" ? "enable-auth = \"certificate\"" : "#enable-auth = \"certificate\"")
            next
        }
        if ($0 ~ /^[[:space:]]*#?[[:space:]]*ca-cert[[:space:]]*=[[:space:]]*\/etc\/ocserv\/ca\/ca-cert\.pem[[:space:]]*$/) {
            print (enable_cert_auth == "true" ? "ca-cert = /etc/ocserv/ca/ca-cert.pem" : "#ca-cert = /etc/ocserv/ca/ca-cert.pem")
            next
        }
        if ($0 ~ /^[[:space:]]*#?[[:space:]]*crl[[:space:]]*=[[:space:]]*\/etc\/ocserv\/ca\/crl\.pem[[:space:]]*$/) {
            print (enable_cert_auth == "true" ? "crl = /etc/ocserv/ca/crl.pem" : "#crl = /etc/ocserv/ca/crl.pem")
            next
        }
        if ($0 ~ /^[[:space:]]*#?[[:space:]]*auth[[:space:]]*=[[:space:]]*"saml\[config=[^]]*\]"[[:space:]]*$/) {
            if (enable_saml_auth == "true" && saml_config_path != "") {
                print "auth = \"saml[config=" saml_config_path "]\""
            } else {
                print "#auth = \"saml[config=/etc/ocserv/saml/config.ini]\""
            }
            next
        }
        # plain auth and SAML auth are mutually exclusive
        if ($0 ~ /^[[:space:]]*#?[[:space:]]*auth[[:space:]]*=[[:space:]]*"plain\[passwd=\/etc\/ocserv\/auth\/ocpasswd\]"[[:space:]]*$/) {
            print (enable_saml_auth == "true" ? "#auth = \"plain[passwd=/etc/ocserv/auth/ocpasswd]\"" : "auth = \"plain[passwd=/etc/ocserv/auth/ocpasswd]\"")
            next
        }
        if ($0 ~ /^[[:space:]]*#?[[:space:]]*compression[[:space:]]*=/) {
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
# shellcheck disable=SC2016
if grep -q '\${HOSTNAME}' "${TMP_FILE}"; then
    fail "unrendered HOSTNAME placeholder remains in generated config"
fi

chmod 0644 "${TMP_FILE}"

# Verify at least one auth method is active
_has_auth=false
grep -qE '^[[:space:]]*auth[[:space:]]*=' "${TMP_FILE}" && _has_auth=true
grep -qE '^[[:space:]]*enable-auth[[:space:]]*=' "${TMP_FILE}" && _has_auth=true
[ "${_has_auth}" = true ] || fail "no auth method enabled: at least one of plain auth, SAML auth, or certificate auth must be active"

mv "${TMP_FILE}" "${OUTPUT_FILE}"
trap - EXIT HUP INT TERM

printf 'Rendered %s from %s using DOMAIN=%s HOSTNAME=%s OCSERV_MAX_CLIENTS=%s OCSERV_ENABLE_CERT_AUTH=%s OCSERV_ENABLE_COMPRESSION=%s OCSERV_NO_UDP=%s OCSERV_ENABLE_SAML_AUTH=%s OCSERV_SAML_CONFIG_PATH=%s\n' \
    "${OUTPUT_FILE}" "${TEMPLATE_FILE}" "${DOMAIN}" "${OCSERV_HOSTNAME}" "${OCSERV_MAX_CLIENTS}" "${OCSERV_ENABLE_CERT_AUTH}" "${OCSERV_ENABLE_COMPRESSION}" "${OCSERV_NO_UDP}" "${OCSERV_ENABLE_SAML_AUTH}" "${OCSERV_SAML_CONFIG_PATH}"
