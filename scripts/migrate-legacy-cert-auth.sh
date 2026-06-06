#!/bin/sh
set -eu

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
Usage:
  ./scripts/migrate-legacy-cert-auth.sh --legacy-root /path/to/old/ocserv-auth
  ./scripts/migrate-legacy-cert-auth.sh --legacy-root /path/to/old/ocserv-auth --apply

Options:
  --legacy-root <path>   Old ocserv-auth project root
  --apply                Execute the migration; default is dry-run
  --backup-dir <path>    Optional backup directory
EOF
}

resolve_dir() {
    target=$1
    [ -d "${target}" ] || fail "directory not found: ${target}"
    (
        unset CDPATH
        cd -- "${target}" && pwd
    )
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
PROJECT_ROOT=$(
    unset CDPATH
    cd -- "${SCRIPT_DIR}/.." && pwd
)
ENV_FILE="${PROJECT_ROOT}/.env"
RENDER_SCRIPT="${PROJECT_ROOT}/scripts/render-ocserv-conf.sh"
CONFIG_DIR="${PROJECT_ROOT}/config"
AUTH_DIR="${CONFIG_DIR}/auth"
AUTH_FILE="${AUTH_DIR}/ocpasswd"
CA_PUBLIC_DIR="${CONFIG_DIR}/client-ca/public"
CA_PRIVATE_DIR="${CONFIG_DIR}/client-ca/private"
USER_CERT_DIR="${CONFIG_DIR}/user-certs"
CONFIG_PER_USER_DIR="${CONFIG_DIR}/config-per-user"
ISSUED_CERT_DIR="${CA_PRIVATE_DIR}/issued-certs"
OCSERV_CONF="${CONFIG_DIR}/ocserv.conf"

APPLY=false
LEGACY_ROOT=""
BACKUP_DIR=""

while [ "$#" -gt 0 ]; do
    case "${1}" in
        --legacy-root)
            [ "$#" -ge 2 ] || fail "--legacy-root requires a path"
            LEGACY_ROOT=$2
            shift 2
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --backup-dir)
            [ "$#" -ge 2 ] || fail "--backup-dir requires a path"
            BACKUP_DIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "unknown argument: $1"
            ;;
    esac
done

[ -n "${LEGACY_ROOT}" ] || fail "--legacy-root is required"

LEGACY_ROOT=$(resolve_dir "${LEGACY_ROOT}")
if [ -n "${BACKUP_DIR}" ]; then
    case "${BACKUP_DIR}" in
        /*) ;;
        *) BACKUP_DIR="${PROJECT_ROOT}/${BACKUP_DIR}" ;;
    esac
else
    BACKUP_DIR="${PROJECT_ROOT}/backups/cert-auth-migration/$(date +%Y%m%d%H%M%S)"
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/legacy-cert-migration.XXXXXX")
trap 'rm -rf "${TMP_DIR}"' EXIT HUP INT TERM
USER_LIST_FILE="${TMP_DIR}/users.txt"
LEGACY_OCPASSWD="${LEGACY_ROOT}/ocpasswd"
LEGACY_CA_DIR="${LEGACY_ROOT}/ca"
LEGACY_USER_CERT_DIR="${LEGACY_ROOT}/user-certs"
LEGACY_CONFIG_PER_USER_DIR="${LEGACY_ROOT}/config-per-user"
VALID_USER_COUNT=0

load_valid_users() {
    : > "${USER_LIST_FILE}"
    VALID_USER_COUNT=0

    while IFS=: read -r raw_user _; do
        user=$(printf '%s' "${raw_user}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "${user}" in
            ""|\#*)
                continue
                ;;
        esac
        if ! printf '%s\n' "${user}" | grep -Eq '^[A-Za-z0-9_-]+$'; then
            warn "skipping unsupported username: ${user}"
            continue
        fi
        printf '%s\n' "${user}" >> "${USER_LIST_FILE}"
        VALID_USER_COUNT=$((VALID_USER_COUNT + 1))
    done < "${LEGACY_OCPASSWD}"

    [ "${VALID_USER_COUNT}" -gt 0 ] || fail "no valid usernames found in ${LEGACY_OCPASSWD}"
}

check_render_preflight() {
    [ -f "${ENV_FILE}" ] || fail "env file not found: ${ENV_FILE}"
    [ -x "${RENDER_SCRIPT}" ] || fail "render script is not executable: ${RENDER_SCRIPT}"

    render_probe=$(mktemp "${TMPDIR:-/tmp}/ocserv-render-preflight.XXXXXX")
    if ! OCSERV_CONF_OUTPUT="${render_probe}" "${RENDER_SCRIPT}" >/dev/null 2>&1; then
        rm -f "${render_probe}"
        fail "render preflight failed; verify ${ENV_FILE} and DOMAIN before migration"
    fi
    rm -f "${render_probe}"
}

check_docker_preflight() {
    require_command docker
    docker compose version >/dev/null 2>&1 || fail "docker compose is unavailable"
}

check_legacy_layout() {
    [ -f "${LEGACY_OCPASSWD}" ] || fail "legacy ocpasswd not found: ${LEGACY_OCPASSWD}"
    [ -f "${LEGACY_CA_DIR}/ca-cert.pem" ] || fail "legacy CA certificate not found: ${LEGACY_CA_DIR}/ca-cert.pem"
    [ -f "${LEGACY_CA_DIR}/ca-key.pem" ] || fail "legacy CA private key not found: ${LEGACY_CA_DIR}/ca-key.pem"
    [ -f "${LEGACY_CA_DIR}/crl.pem" ] || fail "legacy CRL not found: ${LEGACY_CA_DIR}/crl.pem"
    [ -d "${LEGACY_USER_CERT_DIR}" ] || fail "legacy user-certs directory not found: ${LEGACY_USER_CERT_DIR}"
}

inspect_legacy_users() {
    while IFS= read -r user; do
        user_dir="${LEGACY_USER_CERT_DIR}/${user}"
        cert_file="${user_dir}/${user}-cert.pem"
        p12_file="${user_dir}/${user}.p12"
        ios_file="${user_dir}/ios-${user}.p12"

        if [ -f "${cert_file}" ]; then
            info "[${user}] source PEM present; expected to migrate into issued-certs/${user}.pem"
        elif [ -f "${p12_file}" ]; then
            warn "[${user}] missing ${user}-cert.pem; manage will treat this user as missing a certificate and reissue artifacts"
        else
            warn "[${user}] missing ${user}-cert.pem and ${user}.p12; manage will generate fresh artifacts for this user"
        fi

        if [ ! -f "${ios_file}" ]; then
            warn "[${user}] missing ios-${user}.p12; manage may report artifact-missing and post-migration validation can fail"
        fi
    done < "${USER_LIST_FILE}"
}

print_summary() {
    info
    info "Legacy root: ${LEGACY_ROOT}"
    info "Project root: ${PROJECT_ROOT}"
    info "Valid users found: ${VALID_USER_COUNT}"
    if [ -d "${LEGACY_CONFIG_PER_USER_DIR}" ]; then
        info "Legacy config-per-user: present; target directory will be replaced during apply"
    else
        info "Legacy config-per-user: absent; target directory will be preserved during apply"
    fi
    info "Backup directory: ${BACKUP_DIR}"
}

backup_path() {
    src=$1
    rel=$2

    [ -e "${src}" ] || return 0
    mkdir -p "$(dirname -- "${BACKUP_DIR}/${rel}")"
    cp -Rp "${src}" "${BACKUP_DIR}/${rel}"
}

backup_current_state() {
    [ ! -e "${BACKUP_DIR}" ] || fail "backup directory already exists: ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}"

    backup_path "${AUTH_DIR}" "config/auth"
    backup_path "${CA_PUBLIC_DIR}" "config/client-ca/public"
    backup_path "${CA_PRIVATE_DIR}" "config/client-ca/private"
    backup_path "${USER_CERT_DIR}" "config/user-certs"
    backup_path "${CONFIG_PER_USER_DIR}" "config/config-per-user"
    backup_path "${ENV_FILE}" ".env"
    backup_path "${OCSERV_CONF}" "config/ocserv.conf"
}

reset_dir() {
    dir=$1
    rm -rf "${dir}"
    mkdir -p "${dir}"
}

copy_tree_contents() {
    src=$1
    dst=$2

    mkdir -p "${dst}"
    if [ -d "${src}" ]; then
        cp -Rp "${src}/." "${dst}/"
    fi
}

set_target_permissions() {
    mkdir -p "${AUTH_DIR}" "${CA_PUBLIC_DIR}" "${CA_PRIVATE_DIR}" "${USER_CERT_DIR}" "${CONFIG_PER_USER_DIR}"
    chmod 700 "${AUTH_DIR}" "${CA_PRIVATE_DIR}" "${USER_CERT_DIR}"
    chmod 755 "${CA_PUBLIC_DIR}" "${CONFIG_PER_USER_DIR}"
    chmod 600 "${AUTH_FILE}" "${CA_PRIVATE_DIR}/ca-key.pem"
    chmod 644 "${CA_PUBLIC_DIR}/ca-cert.pem" "${CA_PUBLIC_DIR}/crl.pem"
}

update_env_cert_auth() {
    tmp_env="${TMP_DIR}/.env.updated"
    awk '
        BEGIN { updated = 0 }
        {
            if ($0 ~ /^[[:space:]]*(export[[:space:]]+)?OCSERV_ENABLE_CERT_AUTH[[:space:]]*=/) {
                if (!updated) {
                    print "OCSERV_ENABLE_CERT_AUTH=true"
                    updated = 1
                }
                next
            }
            print
        }
        END {
            if (!updated) {
                print "OCSERV_ENABLE_CERT_AUTH=true"
            }
        }
    ' "${ENV_FILE}" > "${tmp_env}"
    mv "${tmp_env}" "${ENV_FILE}"
}

apply_legacy_files() {
    mkdir -p "${CONFIG_DIR}/client-ca"

    reset_dir "${AUTH_DIR}"
    reset_dir "${CA_PUBLIC_DIR}"
    reset_dir "${CA_PRIVATE_DIR}"
    reset_dir "${USER_CERT_DIR}"

    cp "${LEGACY_OCPASSWD}" "${AUTH_FILE}"
    cp "${LEGACY_CA_DIR}/ca-cert.pem" "${CA_PUBLIC_DIR}/ca-cert.pem"
    cp "${LEGACY_CA_DIR}/crl.pem" "${CA_PUBLIC_DIR}/crl.pem"
    cp "${LEGACY_CA_DIR}/ca-key.pem" "${CA_PRIVATE_DIR}/ca-key.pem"
    copy_tree_contents "${LEGACY_USER_CERT_DIR}" "${USER_CERT_DIR}"

    if [ -d "${LEGACY_CONFIG_PER_USER_DIR}" ]; then
        reset_dir "${CONFIG_PER_USER_DIR}"
        copy_tree_contents "${LEGACY_CONFIG_PER_USER_DIR}" "${CONFIG_PER_USER_DIR}"
    fi

    set_target_permissions
}

run_render() {
    "${RENDER_SCRIPT}" >/dev/null
}

run_manage() {
    (
        unset CDPATH
        cd -- "${PROJECT_ROOT}" && docker compose --profile tools run --rm ocserv-auth manage >/dev/null
    )
}

count_issued_certs() {
    if [ ! -d "${ISSUED_CERT_DIR}" ]; then
        printf '0\n'
        return
    fi
    find "${ISSUED_CERT_DIR}" -maxdepth 1 -type f -name '*.pem' | wc -l | tr -d ' '
}

validate_rendered_config() {
    [ -f "${OCSERV_CONF}" ] || fail "rendered ocserv config not found: ${OCSERV_CONF}"
    grep -Fqx 'enable-auth = "certificate"' "${OCSERV_CONF}" || fail "rendered config is missing enable-auth = \"certificate\""
    grep -Fqx 'ca-cert = /etc/ocserv/ca/ca-cert.pem' "${OCSERV_CONF}" || fail "rendered config is missing ca-cert path"
    grep -Fqx 'crl = /etc/ocserv/ca/crl.pem' "${OCSERV_CONF}" || fail "rendered config is missing crl path"
}

validate_static_results() {
    [ -s "${CA_PUBLIC_DIR}/ca-cert.pem" ] || fail "migrated CA certificate is missing or empty"
    [ -s "${CA_PUBLIC_DIR}/crl.pem" ] || fail "migrated CRL is missing or empty"
    [ -s "${CA_PRIVATE_DIR}/ca-key.pem" ] || fail "migrated CA private key is missing or empty"
    [ -d "${ISSUED_CERT_DIR}" ] || fail "issued certificate index directory not found: ${ISSUED_CERT_DIR}"

    validate_rendered_config

    issued_count=$(count_issued_certs)
    [ "${issued_count}" -eq "${VALID_USER_COUNT}" ] || fail "issued certificate count mismatch: expected ${VALID_USER_COUNT}, got ${issued_count}"

    while IFS= read -r user; do
        user_dir="${USER_CERT_DIR}/${user}"
        p12_file="${user_dir}/${user}.p12"
        ios_file="${user_dir}/ios-${user}.p12"
        issued_file="${ISSUED_CERT_DIR}/${user}.pem"

        [ -s "${p12_file}" ] || fail "missing or empty P12 artifact: ${p12_file}"
        [ -s "${ios_file}" ] || fail "missing or empty iOS P12 artifact: ${ios_file}"
        [ -s "${issued_file}" ] || fail "missing or empty issued certificate index: ${issued_file}"
        [ ! -e "${user_dir}/${user}-cert.pem" ] || fail "legacy certificate PEM still present after migration: ${user_dir}/${user}-cert.pem"
        [ ! -e "${user_dir}/${user}-key.pem" ] || fail "legacy key PEM still present after migration: ${user_dir}/${user}-key.pem"
    done < "${USER_LIST_FILE}"
}

print_restore_instructions() {
    info
    info "Manual restore instructions:"
    info "  Backup directory: ${BACKUP_DIR}"
    info "  If you need to revert, restore these paths from the backup before re-running the migration:"
    info "    ${BACKUP_DIR}/config/auth"
    info "    ${BACKUP_DIR}/config/client-ca/public"
    info "    ${BACKUP_DIR}/config/client-ca/private"
    info "    ${BACKUP_DIR}/config/user-certs"
    info "    ${BACKUP_DIR}/config/config-per-user"
    info "    ${BACKUP_DIR}/.env"
    info "    ${BACKUP_DIR}/config/ocserv.conf"
}

print_runtime_checks() {
    info
    info "Optional runtime verification commands:"
    info "  docker compose --profile tools run --rm ocserv-auth status"
    info "  docker compose up -d --force-recreate ocserv"
    info "  docker inspect --format='{{.State.Health.Status}}' ocserv"
    info "  docker exec ocserv occtl show status"
}

main() {
    check_render_preflight
    check_docker_preflight
    check_legacy_layout
    load_valid_users
    inspect_legacy_users
    print_summary

    if [ "${APPLY}" != "true" ]; then
        info
        info "Dry-run only. No files were modified."
        exit 0
    fi

    backup_current_state
    apply_legacy_files
    update_env_cert_auth
    run_render
    run_manage
    validate_static_results

    info
    info "Legacy certificate migration completed successfully."
    print_restore_instructions
    print_runtime_checks
}

main "$@"
