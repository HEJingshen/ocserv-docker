#!/bin/sh
set -eu

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE_FILE="${PROJECT_ROOT}/.env.example"
AUTH_DIR="${PROJECT_ROOT}/config/auth"
AUTH_FILE="${AUTH_DIR}/ocpasswd"
CLIENT_CA_PUBLIC_DIR="${PROJECT_ROOT}/config/client-ca/public"
CLIENT_CA_PRIVATE_DIR="${PROJECT_ROOT}/config/client-ca/private"
USER_CERT_DIR="${PROJECT_ROOT}/config/user-certs"
CONFIG_PER_USER_DIR="${PROJECT_ROOT}/config/config-per-user"
LOG_DIR="${PROJECT_ROOT}/logs"
EDITOR_CMD=${EDITOR:-vi}

cd "${PROJECT_ROOT}"

[ -f "${ENV_EXAMPLE_FILE}" ] || fail "env template not found: ${ENV_EXAMPLE_FILE}"
[ -f "${PROJECT_ROOT}/scripts/render-ocserv-conf.sh" ] || fail "render script not found"

if [ -f "${ENV_FILE}" ]; then
    printf '.env already exists; keeping existing file: %s\n' "${ENV_FILE}"
else
    cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
    printf 'Created %s from .env.example\n' "${ENV_FILE}"
fi

mkdir -p \
    "${LOG_DIR}" \
    "${AUTH_DIR}" \
    "${CLIENT_CA_PUBLIC_DIR}" \
    "${CLIENT_CA_PRIVATE_DIR}" \
    "${USER_CERT_DIR}" \
    "${CONFIG_PER_USER_DIR}"
touch "${AUTH_FILE}"
chmod 700 "${AUTH_DIR}"
chmod 600 "${AUTH_FILE}"
chmod 700 "${CLIENT_CA_PRIVATE_DIR}" "${USER_CERT_DIR}"
chmod 755 "${CLIENT_CA_PUBLIC_DIR}" "${CONFIG_PER_USER_DIR}"

printf '\nEdit environment variables now: %s %s\n' "${EDITOR_CMD}" "${ENV_FILE}"
printf 'At minimum, set DOMAIN. If enabling monitoring, also set GF_ADMIN_PASSWORD.\n\n'

if ! command -v "${EDITOR_CMD}" >/dev/null 2>&1; then
    fail "editor command not found: ${EDITOR_CMD}"
fi

"${EDITOR_CMD}" "${ENV_FILE}" || fail "editor exited with an error: ${EDITOR_CMD}"

"${PROJECT_ROOT}/scripts/render-ocserv-conf.sh"

cat <<'EOF'

Configuration prepared.

Next steps:
  1. Verify TLS certificate paths for DOMAIN in .env.
  2. Start ocserv only:
       docker compose up -d
  3. Or start ocserv with monitoring:
       docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
EOF
