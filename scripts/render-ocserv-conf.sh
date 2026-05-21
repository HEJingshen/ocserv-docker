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

DOMAIN=${DOMAIN:-}
if [ -z "${DOMAIN}" ]; then
    DOMAIN=$(
        awk '
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            /^[[:space:]]*DOMAIN[[:space:]]*=/ {
                value = $0
                sub(/^[[:space:]]*DOMAIN[[:space:]]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]+#.*$/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) {
                    value = substr(value, 2, length(value) - 2)
                }
            }
            END { print value }
        ' "${ENV_FILE}"
    )
fi

[ -n "${DOMAIN:-}" ] || fail "DOMAIN is empty in ${ENV_FILE}"

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

awk -v domain="${DOMAIN}" '{ gsub(/\$\{DOMAIN\}/, domain); print }' "${TEMPLATE_FILE}" > "${TMP_FILE}"

if grep -q '\${DOMAIN}' "${TMP_FILE}"; then
    fail "unrendered DOMAIN placeholder remains in generated config"
fi

chmod 0644 "${TMP_FILE}"
mv "${TMP_FILE}" "${OUTPUT_FILE}"
trap - EXIT HUP INT TERM

printf 'Rendered %s from %s using DOMAIN=%s\n' "${OUTPUT_FILE}" "${TEMPLATE_FILE}" "${DOMAIN}"
