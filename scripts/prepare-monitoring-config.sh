#!/bin/sh
set -eu

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

env_value() {
    value=$(printenv "$1" 2>/dev/null || true)
    if [ -n "${value}" ]; then
        printf '%s' "${value}"
        return
    fi

    awk -v key="$1" '
        /^[[:space:]]*#/ { next }
        {
            line=$0
            sub(/\r$/, "", line)
            if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                value=line
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
                sub(/[[:space:]]*#.*$/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                gsub(/^"|"$/, "", value)
                gsub(/^'\''|'\''$/, "", value)
                print value
                exit
            }
        }
    ' "${ENV_FILE}"
}

require_file_readable() {
    [ -f "$1" ] || fail "$2 not found: $1"
    [ -r "$1" ] || fail "$2 is not readable: $1; check with sudo if permissions are restricted"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE_FILE="${PROJECT_ROOT}/.env.example"
AUTH_DIR="${PROJECT_ROOT}/config/auth"
AUTH_FILE="${AUTH_DIR}/ocpasswd"
LOG_DIR="${PROJECT_ROOT}/logs"
NGINX_CONF_DIR="${PROJECT_ROOT}/nginx/conf.d"
NGINX_LOG_DIR="${PROJECT_ROOT}/nginx/logs"
EDITOR_CMD=${EDITOR:-vi}
SKIP_TLS_CHECK=${SKIP_TLS_CHECK:-false}

cd "${PROJECT_ROOT}"

[ -f "${ENV_EXAMPLE_FILE}" ] || fail "env template not found: ${ENV_EXAMPLE_FILE}"
[ -f "${PROJECT_ROOT}/scripts/render-ocserv-conf.sh" ] || fail "render script not found"

if [ -f "${ENV_FILE}" ]; then
    printf '.env already exists; keeping existing file: %s\n' "${ENV_FILE}"
else
    cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
    printf 'Created %s from .env.example\n' "${ENV_FILE}"
fi

mkdir -p "${LOG_DIR}" "${AUTH_DIR}" "${NGINX_CONF_DIR}" "${NGINX_LOG_DIR}"
touch "${AUTH_FILE}"
chmod 700 "${AUTH_DIR}"
chmod 600 "${AUTH_FILE}"

printf '\nEdit monitoring environment variables now: %s %s\n' "${EDITOR_CMD}" "${ENV_FILE}"
printf 'At minimum, set DOMAIN and GF_ADMIN_PASSWORD before production use.\n\n'

if ! command -v "${EDITOR_CMD}" >/dev/null 2>&1; then
    fail "editor command not found: ${EDITOR_CMD}"
fi

"${EDITOR_CMD}" "${ENV_FILE}" || fail "editor exited with an error: ${EDITOR_CMD}"

"${PROJECT_ROOT}/scripts/render-ocserv-conf.sh"

DOMAIN_VALUE=$(env_value DOMAIN)
GF_ADMIN_PASSWORD_VALUE=$(env_value GF_ADMIN_PASSWORD)

[ -n "${DOMAIN_VALUE}" ] || fail "DOMAIN is empty in ${ENV_FILE}"
[ "${DOMAIN_VALUE}" != "your.domain.com" ] || fail "DOMAIN still uses the example value: ${DOMAIN_VALUE}"
[ -n "${GF_ADMIN_PASSWORD_VALUE}" ] || fail "GF_ADMIN_PASSWORD is empty in ${ENV_FILE}"
[ -d "${NGINX_CONF_DIR}" ] || fail "nginx conf directory not found: ${NGINX_CONF_DIR}"
[ -w "${NGINX_CONF_DIR}" ] || fail "nginx conf directory is not writable: ${NGINX_CONF_DIR}"

case "${SKIP_TLS_CHECK}" in
    true)
        printf 'Skipping TLS certificate readability checks because SKIP_TLS_CHECK=true.\n'
        ;;
    false|"")
        CERT_FILE="/etc/letsencrypt/live/${DOMAIN_VALUE}/fullchain.pem"
        KEY_FILE="/etc/letsencrypt/live/${DOMAIN_VALUE}/privkey.pem"
        require_file_readable "${CERT_FILE}" "TLS certificate"
        require_file_readable "${KEY_FILE}" "TLS private key"
        ;;
    *)
        fail "SKIP_TLS_CHECK must be true or false: ${SKIP_TLS_CHECK}"
        ;;
esac

docker compose -f docker-compose.yml -f docker-compose.monitoring.yml config >/dev/null

cat <<'EOF'

Monitoring configuration prepared.

Next steps:
  1. Start ocserv with monitoring:
       docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
  2. Validate nginx after startup:
       docker exec nginx-proxy nginx -t
EOF
