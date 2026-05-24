#!/bin/sh
set -eu

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

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
OCSERV_DISABLE_UTMP=${OCSERV_DISABLE_UTMP:-$(env_value OCSERV_DISABLE_UTMP)}
OCSERV_DISABLE_UTMP=${OCSERV_DISABLE_UTMP:-false}
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-$(env_value OCSERV_MAX_CLIENTS)}
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-32}

[ -n "${DOMAIN:-}" ] || fail "DOMAIN is empty in ${ENV_FILE}"

case "${OCSERV_DISABLE_UTMP}" in
    true|false)
        ;;
    *)
        fail "OCSERV_DISABLE_UTMP must be true or false: ${OCSERV_DISABLE_UTMP}"
        ;;
esac

case "${OCSERV_MAX_CLIENTS}" in
    ''|*[!0-9]*)
        fail "OCSERV_MAX_CLIENTS must be a positive integer: ${OCSERV_MAX_CLIENTS}"
        ;;
esac
[ "${OCSERV_MAX_CLIENTS}" -ge 1 ] || fail "OCSERV_MAX_CLIENTS must be at least 1"

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

OUTPUT_DIR=$(dirname -- "${OUTPUT_FILE}")
[ -d "${OUTPUT_DIR}" ] || fail "output directory not found: ${OUTPUT_DIR}"

TMP_FILE=$(mktemp "${OUTPUT_DIR}/.ocserv.conf.XXXXXX") || fail "failed to create temporary config"
trap 'rm -f "${TMP_FILE}"' EXIT HUP INT TERM

awk -v domain="${DOMAIN}" \
    -v disable_utmp="${OCSERV_DISABLE_UTMP}" \
    -v max_clients="${OCSERV_MAX_CLIENTS}" '
    {
        gsub(/\$\{DOMAIN\}/, domain)
        if ($0 ~ /^[[:space:]]*max-clients[[:space:]]*=/) {
            sub(/=.*/, "= " max_clients)
        }
        if (disable_utmp == "true" && $0 ~ /^[[:space:]]*use-utmp[[:space:]]*=/) {
            sub(/=.*/, "= false")
        }
        print
    }
' "${TEMPLATE_FILE}" > "${TMP_FILE}"

if grep -q '\${DOMAIN}' "${TMP_FILE}"; then
    fail "unrendered DOMAIN placeholder remains in generated config"
fi

chmod 0644 "${TMP_FILE}"
mv "${TMP_FILE}" "${OUTPUT_FILE}"
trap - EXIT HUP INT TERM

printf 'Rendered %s from %s using DOMAIN=%s OCSERV_MAX_CLIENTS=%s\n' \
    "${OUTPUT_FILE}" "${TEMPLATE_FILE}" "${DOMAIN}" "${OCSERV_MAX_CLIENTS}"
