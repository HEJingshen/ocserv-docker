#!/bin/sh
set -eu

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=scripts/common.sh disable=SC1091
. "${SCRIPT_DIR}/common.sh"

SKIP_EDIT=false
case "${1:-}" in
    --no-edit) SKIP_EDIT=true ;;
    '') ;;
    *) fail "unknown option: $1. Usage: $0 [--no-edit]" ;;
esac

ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE_FILE="${PROJECT_ROOT}/.env.example"
OCSERV_CONF_DIR="/etc/ocserv"
OCSERV_AUTH_DIR="${OCSERV_CONF_DIR}/auth"
LOG_DIR="${PROJECT_ROOT}/logs"
EDITOR_CMD=${EDITOR:-vi}

command -v "${EDITOR_CMD}" >/dev/null 2>&1 || fail "editor command not found: ${EDITOR_CMD}"

cd "${PROJECT_ROOT}"

[ -f "${ENV_EXAMPLE_FILE}" ] || fail "env template not found: ${ENV_EXAMPLE_FILE}"
[ -f "${PROJECT_ROOT}/scripts/render-ocserv-conf.sh" ] || fail "render script not found"

if [ -f "${ENV_FILE}" ]; then
    printf '.env already exists; keeping existing file: %s\n' "${ENV_FILE}"

    # Warn about new variables in .env.example that are missing from .env
    _new_vars=$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[A-Z_][A-Z0-9_]*=/ {
            split($0, a, "=")
            print a[1]
        }
    ' "${ENV_EXAMPLE_FILE}" | while read -r _key; do
        if ! grep -q "^${_key}=" "${ENV_FILE}" 2>/dev/null; then
            printf '  %s\n' "${_key}"
        fi
    done)

    if [ -n "${_new_vars}" ]; then
        printf '\nWARNING: New variables in .env.example not present in your .env:\n%s\n' "${_new_vars}"
        printf 'Consider adding them. See .env.example for default values.\n\n'
    fi
else
    cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
    printf 'Created %s from .env.example\n' "${ENV_FILE}"
fi

mkdir -p "${LOG_DIR}"

# Create ocserv configuration and auth directories on host
mkdir -p "${OCSERV_CONF_DIR}" 2>/dev/null || fail "cannot create ${OCSERV_CONF_DIR} (run with sudo)"
mkdir -p "${OCSERV_AUTH_DIR}" 2>/dev/null || fail "cannot create ${OCSERV_AUTH_DIR} (run with sudo)"
touch "${OCSERV_AUTH_DIR}/ocpasswd" 2>/dev/null || fail "cannot create ${OCSERV_AUTH_DIR}/ocpasswd (run with sudo)"
chmod 700 "${OCSERV_AUTH_DIR}" 2>/dev/null || fail "cannot chmod ${OCSERV_AUTH_DIR} (run with sudo)"
chmod 600 "${OCSERV_AUTH_DIR}/ocpasswd" 2>/dev/null || fail "cannot chmod ocpasswd (run with sudo)"

if [ "${SKIP_EDIT}" = false ]; then
    printf '\nEdit environment variables now: %s %s\n' "${EDITOR_CMD}" "${ENV_FILE}"
    printf 'At minimum, set DOMAIN.\n\n'

    "${EDITOR_CMD}" "${ENV_FILE}" || fail "editor exited with an error: ${EDITOR_CMD}"

    # Check for placeholder DOMAIN value
    _domain_value=$(awk -F= '/^DOMAIN=/{print $2; exit}' "${ENV_FILE}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d "'\"")
    case "${_domain_value}" in
        your.domain.com)
            fail "DOMAIN is still set to the placeholder value 'your.domain.com'. Please set a real domain."
            ;;
    esac
else
    printf 'Skipping editor (--no-edit). Edit %s manually if needed.\n' "${ENV_FILE}"
fi

"${PROJECT_ROOT}/scripts/render-ocserv-conf.sh"

cat <<'EOF'

Configuration prepared.

Next steps:
  1. Verify TLS certificate paths for DOMAIN in .env.
  2. Start ocserv:
       docker compose up -d
EOF
