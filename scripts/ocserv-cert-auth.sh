#!/usr/bin/env bash
set -euo pipefail
umask 077

OCPASSWD=${OCPASSWD:-/etc/ocserv/auth/ocpasswd}
CA_PUBLIC_DIR=${CA_PUBLIC_DIR:-/etc/ocserv/ca}
CA_PRIVATE_DIR=${CA_PRIVATE_DIR:-/var/lib/ocserv-auth/private-ca}
CERT_DIR=${CERT_DIR:-/var/lib/ocserv-auth/user-certs}
CONFIG_PER_USER_DIR=${CONFIG_PER_USER_DIR:-/etc/ocserv/config-per-user}
LOCK_FILE=${LOCK_FILE:-/var/lib/ocserv-auth/ocserv-cert-auth.lock}
ALLOW_EMPTY_P12_PASSWORD=${ALLOW_EMPTY_P12_PASSWORD:-false}
P12_EXPORT_PASSWORD=${P12_EXPORT_PASSWORD:-}

CA_CERT="${CA_PUBLIC_DIR}/ca-cert.pem"
CA_KEY="${CA_PRIVATE_DIR}/ca-key.pem"
CRL_FILE="${CA_PUBLIC_DIR}/crl.pem"
REVOKED_DIR="${CA_PRIVATE_DIR}/revoked"
DISABLED_DIR="${CA_PRIVATE_DIR}/disabled-users"
ISSUED_CERT_DIR="${CA_PRIVATE_DIR}/issued-certs"
REVOKED_METADATA_DIR="${CA_PRIVATE_DIR}/revoked-metadata"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

info() { printf '%s[+]%s %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%s[!]%s %s\n' "${YELLOW}" "${NC}" "$*"; }
error() { printf '%s[-]%s %s\n' "${RED}" "${NC}" "$*" >&2; }
die() { error "$*"; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  ocserv-cert-auth init-ca
  ocserv-cert-auth manage
  ocserv-cert-auth status
  ocserv-cert-auth revoke [--yes|-y] <username> [username...]
  ocserv-cert-auth reissue <username> [username...]
  ocserv-cert-auth menu

Without arguments, the interactive menu is shown.
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

check_dependencies() {
    require_command certtool
    require_command flock
    require_command openssl
    certtool_supports_required_options || die "GNU GnuTLS certtool with certificate generation support is required"
}

check_status_dependencies() {
    require_command openssl
}

certtool_supports_required_options() {
    local help_text
    help_text=$(certtool --help 2>&1 || true)
    printf '%s\n' "${help_text}" | grep -q -- '--generate-self-signed' || return 1
    printf '%s\n' "${help_text}" | grep -q -- '--generate-certificate' || return 1
    printf '%s\n' "${help_text}" | grep -q -- '--generate-crl' || return 1
}

validate_p12_export_policy() {
    case "${ALLOW_EMPTY_P12_PASSWORD}" in
        true|false)
            ;;
        *)
            die "ALLOW_EMPTY_P12_PASSWORD must be true or false: ${ALLOW_EMPTY_P12_PASSWORD}"
            ;;
    esac

    if [[ -z "${P12_EXPORT_PASSWORD}" && "${ALLOW_EMPTY_P12_PASSWORD}" != "true" ]]; then
        die "empty P12 export passwords are disabled; set P12_EXPORT_PASSWORD or ALLOW_EMPTY_P12_PASSWORD=true"
    fi
}

p12_passout_arg() {
    if [[ -n "${P12_EXPORT_PASSWORD}" ]]; then
        printf 'pass:%s\n' "${P12_EXPORT_PASSWORD}"
        return 0
    fi
    if [[ "${ALLOW_EMPTY_P12_PASSWORD}" == "true" ]]; then
        printf 'pass:\n'
        return 0
    fi
    return 1
}

p12_uses_empty_password() {
    [[ -z "${P12_EXPORT_PASSWORD}" && "${ALLOW_EMPTY_P12_PASSWORD}" == "true" ]]
}

prepare_dirs() {
    mkdir -p \
        "${CA_PUBLIC_DIR}" \
        "${CA_PRIVATE_DIR}" \
        "${CERT_DIR}" \
        "${CONFIG_PER_USER_DIR}" \
        "${REVOKED_DIR}" \
        "${DISABLED_DIR}" \
        "${ISSUED_CERT_DIR}" \
        "${REVOKED_METADATA_DIR}" \
        "$(dirname -- "${LOCK_FILE}")"
    chmod 700 "${CA_PRIVATE_DIR}" "${CERT_DIR}" "${REVOKED_DIR}" "${DISABLED_DIR}" "${ISSUED_CERT_DIR}" "${REVOKED_METADATA_DIR}" 2>/dev/null || true
}

load_users() {
    [[ -f "${OCPASSWD}" ]] || die "ocpasswd not found: ${OCPASSWD}"
    [[ -r "${OCPASSWD}" ]] || die "ocpasswd is not readable: ${OCPASSWD}"

    usernames=()
    local user
    while IFS=: read -r user _; do
        [[ -z "${user}" || "${user}" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "${user}" =~ ^[A-Za-z0-9_-]+$ ]]; then
            warn "skipping unsupported username: ${user}"
            continue
        fi
        usernames+=("${user}")
    done < "${OCPASSWD}"

    [[ "${#usernames[@]}" -gt 0 ]] || die "no usable users found in ${OCPASSWD}"
}

user_exists() {
    local candidate=$1
    local user
    for user in "${usernames[@]}"; do
        [[ "${user}" == "${candidate}" ]] && return 0
    done
    return 1
}

disabled_marker() {
    printf '%s/%s\n' "${DISABLED_DIR}" "$1"
}

is_user_disabled() {
    [[ -f "$(disabled_marker "$1")" ]]
}

issued_cert_file() {
    printf '%s/%s.pem\n' "${ISSUED_CERT_DIR}" "$1"
}

legacy_user_cert_file() {
    printf '%s/%s/%s-cert.pem\n' "${CERT_DIR}" "$1" "$1"
}

current_user_cert_file() {
    local username=$1 issued legacy
    issued=$(issued_cert_file "${username}")
    legacy=$(legacy_user_cert_file "${username}")
    if [[ -f "${issued}" ]]; then
        printf '%s\n' "${issued}"
        return 0
    fi
    if [[ -f "${legacy}" ]]; then
        printf '%s\n' "${legacy}"
        return 0
    fi
    return 1
}

user_p12_artifacts_present() {
    local username=$1 user_dir="${CERT_DIR}/${username}"
    [[ -s "${user_dir}/${username}.p12" && -s "${user_dir}/ios-${username}.p12" ]]
}

cleanup_user_pem_artifacts() {
    local username=$1 user_dir="${CERT_DIR}/${username}"
    rm -f "${user_dir}"/*-cert.pem "${user_dir}"/*-key.pem
}

openssl_major() {
    openssl version 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) {split($i,a,"."); print a[1]; exit}}'
}

cert_days_left() {
    local cert_file=$1
    [[ -f "${cert_file}" ]] || { printf 'none\n'; return; }

    local end_date end_ts now_ts
    end_date=$(openssl x509 -in "${cert_file}" -noout -enddate 2>/dev/null | sed 's/notAfter=//') || {
        printf 'error\n'
        return
    }
    [[ -n "${end_date}" ]] || { printf 'error\n'; return; }

    end_ts=$(date -d "${end_date}" +%s 2>/dev/null || date -jf "%b %e %T %Y %Z" "${end_date}" +%s 2>/dev/null || printf '0')
    now_ts=$(date +%s)
    [[ "${end_ts}" != "0" ]] || { printf 'error\n'; return; }
    printf '%s\n' "$(((end_ts - now_ts) / 86400))"
}

cert_serial() {
    openssl x509 -in "$1" -noout -serial 2>/dev/null | sed 's/^serial=//' | tr '[:lower:]' '[:upper:]'
}

is_cert_revoked() {
    local cert_file=$1
    [[ -f "${cert_file}" && -f "${CRL_FILE}" ]] || return 1

    local serial revoked_serials
    serial=$(cert_serial "${cert_file}") || return 1
    [[ -n "${serial}" ]] || return 1
    revoked_serials=$(openssl crl -in "${CRL_FILE}" -noout -text 2>/dev/null |
        awk '/Revoked Certificates:/,/Signature Algorithm:/ {
            if ($0 ~ /Serial Number:/) {
                print $NF
            }
        }' | tr -d ' :' | tr '[:lower:]' '[:upper:]')

    grep -qx "${serial}" <<< "${revoked_serials}"
}

write_initial_crl() {
    local tmpl tmp_file
    tmpl=$(mktemp "${CA_PRIVATE_DIR}/crl-template.XXXXXX")
    tmp_file=$(mktemp "${CA_PUBLIC_DIR}/.crl.XXXXXX")
    cat > "${tmpl}" <<'EOF'
crl_next_update = 3650
crl_number = 1
EOF
    certtool --generate-crl \
        --load-ca-certificate "${CA_CERT}" \
        --load-ca-privkey "${CA_KEY}" \
        --template "${tmpl}" \
        --outfile "${tmp_file}" >/dev/null 2>&1
    chmod 644 "${tmp_file}"
    mv "${tmp_file}" "${CRL_FILE}"
    rm -f "${tmpl}"
}

ensure_ca() {
    prepare_dirs

    local ca_status
    ca_status=$(cert_days_left "${CA_CERT}")

    if [[ "${ca_status}" == "none" || ! -f "${CA_KEY}" ]]; then
        info "generating client certificate CA"
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "${CA_KEY}" >/dev/null 2>&1
        chmod 600 "${CA_KEY}"

        local ca_serial tmpl
        ca_serial=$(openssl rand -hex 10)
        ca_serial="0${ca_serial:1}"
        tmpl=$(mktemp "${CA_PRIVATE_DIR}/ca-template.XXXXXX")
        cat > "${tmpl}" <<EOF
cn = "ocserv client auth CA"
organization = "ocserv-docker"
serial = 0x${ca_serial}
expiration_days = 11680
ca
signing_key
cert_signing_key
crl_signing_key
EOF
        certtool --generate-self-signed \
            --load-privkey "${CA_KEY}" \
            --template "${tmpl}" \
            --outfile "${CA_CERT}" >/dev/null 2>&1
        chmod 644 "${CA_CERT}"
        rm -f "${tmpl}"
    elif [[ "${ca_status}" == "error" ]]; then
        die "client CA certificate is unreadable or invalid: ${CA_CERT}"
    elif [[ "${ca_status}" -le 0 ]]; then
        die "client CA certificate has expired; rotate it manually after backing up ${CA_PUBLIC_DIR} and ${CA_PRIVATE_DIR}"
    fi

    [[ -f "${CRL_FILE}" ]] || write_initial_crl
}

generate_user_cert_into_dir() {
    local username=$1
    local user_dir=$2
    local key_file="${user_dir}/${username}-key.pem"
    local cert_file="${user_dir}/${username}-cert.pem"
    local p12_file="${user_dir}/${username}.p12"
    local ios_p12_file="${user_dir}/ios-${username}.p12"
    local tmpl_file="${user_dir}/${username}.tmpl"
    local serial openssl_major_version passout_arg
    local -a ios_args

    mkdir -p "${user_dir}" || return 1
    passout_arg=$(p12_passout_arg) || return 1
    serial=$(openssl rand -hex 10 2>/dev/null) || return 1
    serial="0${serial:1}"

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${key_file}" >/dev/null 2>&1 || return 1
    chmod 600 "${key_file}" || return 1

    cat > "${tmpl_file}" <<EOF || return 1
cn = "${username}"
uid = "${username}"
serial = 0x${serial}
expiration_days = 3650
signing_key
encryption_key
tls_www_client
EOF

    certtool --generate-certificate \
        --load-privkey "${key_file}" \
        --load-ca-certificate "${CA_CERT}" \
        --load-ca-privkey "${CA_KEY}" \
        --template "${tmpl_file}" \
        --outfile "${cert_file}" >/dev/null 2>&1 || { rm -f "${tmpl_file}"; return 1; }
    chmod 644 "${cert_file}" || { rm -f "${tmpl_file}"; return 1; }

    openssl pkcs12 -export \
        -inkey "${key_file}" \
        -in "${cert_file}" \
        -certfile "${CA_CERT}" \
        -name "${username}" \
        -out "${p12_file}" \
        -passout "${passout_arg}" >/dev/null 2>&1 || { rm -f "${tmpl_file}"; return 1; }

    openssl_major_version=$(openssl_major || printf '0')
    ios_args=(-export -descert)
    if [[ "${openssl_major_version:-0}" -ge 3 ]]; then
        ios_args+=(-legacy)
    fi
    openssl pkcs12 "${ios_args[@]}" \
        -inkey "${key_file}" \
        -in "${cert_file}" \
        -certfile "${CA_CERT}" \
        -name "${username}" \
        -out "${ios_p12_file}" \
        -passout "${passout_arg}" >/dev/null 2>&1 || { rm -f "${tmpl_file}"; return 1; }

    rm -f "${tmpl_file}" || return 1
    [[ -s "${p12_file}" && -s "${ios_p12_file}" ]] || return 1
}

install_generated_user_cert() {
    local username=$1
    local source_dir=$2
    local user_dir="${CERT_DIR}/${username}"
    local issued_cert
    issued_cert=$(issued_cert_file "${username}")

    mkdir -p "${user_dir}" "${ISSUED_CERT_DIR}" || return 1
    cp "${source_dir}/${username}.p12" "${user_dir}/${username}.p12" || return 1
    cp "${source_dir}/ios-${username}.p12" "${user_dir}/ios-${username}.p12" || return 1
    cp "${source_dir}/${username}-cert.pem" "${issued_cert}" || return 1
    chmod 600 "${user_dir}/${username}.p12" "${user_dir}/ios-${username}.p12" || return 1
    chmod 644 "${issued_cert}" || return 1
    cleanup_user_pem_artifacts "${username}" || return 1
}

generate_user_cert() {
    local username=$1
    local tmp_dir
    tmp_dir=$(mktemp -d "${CERT_DIR}/.tmp-${username}.XXXXXX") || return 1
    if ! generate_user_cert_into_dir "${username}" "${tmp_dir}"; then
        rm -rf "${tmp_dir}"
        return 1
    fi
    if ! install_generated_user_cert "${username}" "${tmp_dir}"; then
        rm -rf "${tmp_dir}"
        return 1
    fi
    rm -rf "${tmp_dir}" || return 1
}

migrate_legacy_user_cert() {
    local username=$1
    local issued legacy
    issued=$(issued_cert_file "${username}")
    legacy=$(legacy_user_cert_file "${username}")

    if [[ ! -f "${issued}" && -f "${legacy}" ]]; then
        mkdir -p "${ISSUED_CERT_DIR}" || return 1
        cp "${legacy}" "${issued}" || return 1
        chmod 644 "${issued}" || return 1
        cleanup_user_pem_artifacts "${username}" || return 1
        info "[${username}] migrated certificate state to ${ISSUED_CERT_DIR}"
    elif [[ -f "${issued}" ]]; then
        cleanup_user_pem_artifacts "${username}" || return 1
    fi
}

cert_status_for_user() {
    local username=$1
    local cert_file
    local days_left

    if is_user_disabled "${username}"; then
        printf '%s\trevoked\tcertificate reissue is disabled\n' "${username}"
        return
    fi
    if ! cert_file=$(current_user_cert_file "${username}"); then
        printf '%s\tmissing\tneeds generation\n' "${username}"
        return
    fi
    if is_cert_revoked "${cert_file}"; then
        printf '%s\trevoked\tcertificate is listed in CRL\n' "${username}"
        return
    fi

    days_left=$(cert_days_left "${cert_file}")
    case "${days_left}" in
        error)
            printf '%s\terror\tcertificate is invalid\n' "${username}"
            ;;
        -*|0)
            printf '%s\texpired\texpired %s days ago\n' "${username}" "${days_left#-}"
            ;;
        *)
            if ! user_p12_artifacts_present "${username}"; then
                printf '%s\tartifact-missing\tcertificate is valid but p12 artifacts are missing; revoke and reissue\n' "${username}"
                return
            fi
            printf '%s\tvalid\t%s days left\n' "${username}" "${days_left}"
            ;;
    esac
}

show_status() {
    load_users

    if [[ ! -f "${CA_CERT}" ]]; then
        warn "ca-missing: ${CA_CERT}"
    fi
    if [[ ! -f "${CRL_FILE}" ]]; then
        warn "crl-missing: ${CRL_FILE}"
    fi

    printf '%-24s %-12s %s\n' "USER" "STATUS" "DETAIL"
    printf '%-24s %-12s %s\n' "----" "------" "------"
    local line user status detail
    for user in "${usernames[@]}"; do
        line=$(cert_status_for_user "${user}")
        IFS=$'\t' read -r user status detail <<< "${line}"
        printf '%-24s %-12s %s\n' "${user}" "${status}" "${detail}"
    done
}

manage_certs() {
    validate_p12_export_policy
    load_users
    ensure_ca

    local user status detail line renewed=0
    for user in "${usernames[@]}"; do
        if is_user_disabled "${user}"; then
            info "[${user}] revoked; skipping automatic reissue"
            continue
        fi
        migrate_legacy_user_cert "${user}" || die "failed to migrate certificate state for ${user}"
        line=$(cert_status_for_user "${user}")
        IFS=$'\t' read -r _ status detail <<< "${line}"
        case "${status}" in
            valid)
                info "[${user}] valid; ${detail}"
                ;;
            artifact-missing)
                warn "[${user}] ${status}; ${detail}"
                ;;
            *)
                info "[${user}] ${status}; generating certificate"
                generate_user_cert "${user}" || die "failed to generate certificate for ${user}"
                renewed=$((renewed + 1))
                ;;
        esac
    done

    info "certificate management complete; generated or renewed ${renewed} user certificate(s)"
    if p12_uses_empty_password; then
        warn "p12 files are exported with an empty import password because ALLOW_EMPTY_P12_PASSWORD=true; protect ${CERT_DIR} on the host"
    else
        info "p12 files are protected by the configured import password"
    fi
}

rebuild_crl_from_revoked_store() {
    local tmpl tmp_file certs=()
    tmpl=$(mktemp "${CA_PRIVATE_DIR}/crl-template.XXXXXX")
    tmp_file=$(mktemp "${CA_PUBLIC_DIR}/.crl.XXXXXX")
    cat > "${tmpl}" <<EOF
crl_next_update = 3650
crl_number = $(date +%s)
EOF

    while IFS= read -r -d '' cert; do
        certs+=(--load-certificate "${cert}")
    done < <(find "${REVOKED_DIR}" -type f -name '*.pem' -print0)

    certtool --generate-crl \
        --load-ca-certificate "${CA_CERT}" \
        --load-ca-privkey "${CA_KEY}" \
        "${certs[@]}" \
        --template "${tmpl}" \
        --outfile "${tmp_file}" >/dev/null 2>&1
    chmod 644 "${tmp_file}"
    mv "${tmp_file}" "${CRL_FILE}"
    rm -f "${tmpl}"
}

join_usernames() {
    local IFS=,
    printf '%s\n' "$*"
}

confirm_revoke_users() {
    local expected input
    expected=$(join_usernames "$@")
    warn "about to revoke client certificates for: ${expected}"
    warn "this removes current p12 files and issued certificate state, writes disabled markers, and updates the CRL"
    read -r -p "Type ${expected} to confirm revoke: " input || die "revoke cancelled"
    [[ "${input}" == "${expected}" ]] || die "revoke cancelled"
}

revoke_users() {
    local skip_confirm=false
    if [[ "${1:-}" == "--skip-confirm" ]]; then
        skip_confirm=true
        shift || true
    fi
    [[ "$#" -gt 0 ]] || die "revoke requires at least one username"
    load_users
    ensure_ca

    local user cert_file marker_file
    local -a revoke_targets=()
    for user in "$@"; do
        [[ "${user}" =~ ^[A-Za-z0-9_-]+$ ]] || die "unsupported username: ${user}"
        user_exists "${user}" || die "user not found in ocpasswd: ${user}"
        marker_file=$(disabled_marker "${user}")
        if [[ -f "${marker_file}" ]]; then
            if ! current_user_cert_file "${user}" >/dev/null; then
                info "[${user}] already revoked; keeping disabled marker"
                continue
            fi
            warn "[${user}] disabled marker exists but certificate file is present; revoking current file"
        fi
        cert_file=$(current_user_cert_file "${user}") || die "certificate not found for ${user}"
        revoke_targets+=("${user}")
    done

    if [[ "${#revoke_targets[@]}" -eq 0 ]]; then
        return 0
    fi
    if [[ "${skip_confirm}" != "true" ]]; then
        confirm_revoke_users "${revoke_targets[@]}"
    fi

    local serial metadata_file revoked_cert issued_file
    for user in "${revoke_targets[@]}"; do
        cert_file=$(current_user_cert_file "${user}") || die "certificate not found for ${user}"
        marker_file=$(disabled_marker "${user}")
        issued_file=$(issued_cert_file "${user}")
        serial=$(cert_serial "${cert_file}")
        revoked_cert="${REVOKED_DIR}/${user}-${serial}.pem"
        metadata_file="${REVOKED_METADATA_DIR}/${user}-${serial}.env"
        cp "${cert_file}" "${revoked_cert}"
        chmod 600 "${revoked_cert}"

        mkdir -p "${REVOKED_METADATA_DIR}"
        rm -f "${CERT_DIR}/${user}"/*.p12 "${CERT_DIR}/${user}"/*-cert.pem "${CERT_DIR}/${user}"/*-key.pem
        rm -f "${issued_file}"
        {
            printf 'revoked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'username=%s\n' "${user}"
            printf 'serial=%s\n' "${serial}"
            printf 'revoked_cert=%s\n' "${revoked_cert}"
        } > "${metadata_file}"
        chmod 600 "${metadata_file}"
        {
            printf 'revoked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'username=%s\n' "${user}"
            printf 'serial=%s\n' "${serial}"
            printf 'metadata=%s\n' "${metadata_file}"
        } > "${marker_file}"
        chmod 600 "${marker_file}"
        info "[${user}] certificate staged for revocation and metadata written to ${metadata_file}"
    done

    rebuild_crl_from_revoked_store
    info "CRL updated: ${CRL_FILE}"
}

revoke_from_cli() {
    local skip_confirm=false
    local -a users=()
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --yes|-y)
                skip_confirm=true
                ;;
            -*)
                die "unknown revoke option: ${arg}"
                ;;
            *)
                users+=("${arg}")
                ;;
        esac
    done
    [[ "${#users[@]}" -gt 0 ]] || die "revoke requires at least one username"
    if [[ "${skip_confirm}" == "true" ]]; then
        revoke_users --skip-confirm "${users[@]}"
    else
        revoke_users "${users[@]}"
    fi
}

reissue_users() {
    [[ "$#" -gt 0 ]] || die "reissue requires at least one username"
    validate_p12_export_policy
    load_users
    ensure_ca

    local user marker_file tmp_dir user_dir backup_dir issued_file issued_backup
    for user in "$@"; do
        [[ "${user}" =~ ^[A-Za-z0-9_-]+$ ]] || die "unsupported username: ${user}"
        user_exists "${user}" || die "user not found in ocpasswd: ${user}"
        marker_file=$(disabled_marker "${user}")
        [[ -f "${marker_file}" ]] || die "user is not revoked; run revoke before reissue: ${user}"

        tmp_dir=$(mktemp -d "${CERT_DIR}/.tmp-${user}.XXXXXX")
        if ! generate_user_cert_into_dir "${user}" "${tmp_dir}"; then
            rm -rf "${tmp_dir}"
            die "failed to reissue certificate for ${user}; disabled marker preserved"
        fi

        user_dir="${CERT_DIR}/${user}"
        issued_file=$(issued_cert_file "${user}")
        backup_dir=""
        issued_backup=""
        if [[ -d "${user_dir}" ]]; then
            if ! backup_dir=$(mktemp -d "${CERT_DIR}/.old-${user}.XXXXXX"); then
                rm -rf "${tmp_dir}"
                die "failed to prepare backup directory for ${user}; disabled marker preserved"
            fi
            if ! rmdir "${backup_dir}"; then
                rm -rf "${tmp_dir}" "${backup_dir}"
                die "failed to prepare backup directory for ${user}; disabled marker preserved"
            fi
            if ! mv "${user_dir}" "${backup_dir}"; then
                rm -rf "${tmp_dir}" "${backup_dir}"
                die "failed to back up existing certificate directory for ${user}; disabled marker preserved"
            fi
        fi
        if [[ -f "${issued_file}" ]]; then
            if ! issued_backup=$(mktemp "${CA_PRIVATE_DIR}/.old-issued-${user}.XXXXXX"); then
                rm -rf "${tmp_dir}"
                if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
                    mv "${backup_dir}" "${user_dir}" 2>/dev/null || true
                fi
                die "failed to prepare issued certificate backup for ${user}; disabled marker preserved"
            fi
            if ! mv "${issued_file}" "${issued_backup}"; then
                rm -rf "${tmp_dir}" "${issued_backup}"
                if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
                    mv "${backup_dir}" "${user_dir}" 2>/dev/null || true
                fi
                die "failed to back up issued certificate for ${user}; disabled marker preserved"
            fi
        fi
        if ! install_generated_user_cert "${user}" "${tmp_dir}"; then
            if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
                rm -rf "${user_dir}" 2>/dev/null || true
                mv "${backup_dir}" "${user_dir}" 2>/dev/null || true
            fi
            if [[ -n "${issued_backup}" && -f "${issued_backup}" ]]; then
                mv "${issued_backup}" "${issued_file}" 2>/dev/null || true
            else
                rm -f "${issued_file}" 2>/dev/null || true
            fi
            rm -rf "${tmp_dir}"
            die "failed to install reissued certificate for ${user}; disabled marker preserved"
        fi
        rm -rf "${tmp_dir}"
        if ! rm -f "${marker_file}"; then
            rm -rf "${user_dir}" 2>/dev/null || {
                chmod -R u+rwX "${user_dir}" 2>/dev/null || true
                rm -rf "${user_dir}" 2>/dev/null || true
            }
            rm -f "${issued_file}" 2>/dev/null || true
            if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
                mv "${backup_dir}" "${user_dir}" 2>/dev/null || true
            fi
            if [[ -n "${issued_backup}" && -f "${issued_backup}" ]]; then
                mv "${issued_backup}" "${issued_file}" 2>/dev/null || true
            fi
            die "failed to clear disabled marker for ${user}; disabled marker preserved and previous certificate state restored where possible"
        fi
        if [[ -n "${backup_dir}" ]]; then
            if ! rm -rf "${backup_dir}"; then
                chmod -R u+rwX "${backup_dir}" 2>/dev/null || true
                rm -rf "${backup_dir}" || die "failed to remove old backup directory containing private key material: ${backup_dir}"
            fi
        fi
        if [[ -n "${issued_backup}" ]]; then
            rm -f "${issued_backup}" || die "failed to remove old issued certificate backup: ${issued_backup}"
        fi
        info "[${user}] certificate reissued"
    done
}

interactive_revoke() {
    command -v fzf >/dev/null 2>&1 || die "fzf is required for interactive revoke"
    load_users
    ensure_ca

    local selected users=()
    selected=$(printf '%s\n' "${usernames[@]}" | fzf --multi --header "Select users to revoke" 2>/dev/tty) || true
    [[ -n "${selected}" ]] || { warn "no users selected"; return; }
    while IFS= read -r user; do
        [[ -n "${user}" ]] && users+=("${user}")
    done <<< "${selected}"
    revoke_users "${users[@]}"
}

menu() {
    while true; do
        cat <<'EOF'

ocserv certificate auth management
1) Generate / renew user certificates
2) Revoke user certificates
3) Show certificate status
4) Reissue revoked user certificates
0) Exit
EOF
        read -r -p "Choose [0-4]: " choice
        case "${choice}" in
            1) with_lock manage_certs ;;
            2) with_lock interactive_revoke ;;
            3) show_status ;;
            4)
                read -r -p "Users to reissue (space separated): " reissue_input
                # shellcheck disable=SC2086
                with_lock reissue_users ${reissue_input}
                ;;
            0) exit 0 ;;
            *) warn "invalid choice" ;;
        esac
    done
}

with_lock() {
    local action=$1
    shift || true
    prepare_dirs
    (
        flock -x 9 || die "failed to acquire lock: ${LOCK_FILE}"
        "${action}" "$@"
    ) 9>"${LOCK_FILE}"
}

main() {
    case "${1:-menu}" in
        manage)
            check_dependencies
            shift || true
            with_lock manage_certs "$@"
            ;;
        init-ca)
            check_dependencies
            shift || true
            with_lock ensure_ca "$@"
            ;;
        status)
            check_status_dependencies
            shift || true
            show_status "$@"
            ;;
        revoke)
            check_dependencies
            shift || true
            with_lock revoke_from_cli "$@"
            ;;
        reissue)
            check_dependencies
            shift || true
            with_lock reissue_users "$@"
            ;;
        menu)
            check_dependencies
            shift || true
            menu "$@"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
