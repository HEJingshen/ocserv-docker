#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MIGRATE_SCRIPT="${ROOT_DIR}/scripts/migrate-legacy-cert-auth.sh"
RENDER_SCRIPT="${ROOT_DIR}/scripts/render-ocserv-conf.sh"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

make_case_dir() {
    mktemp -d "${TMPDIR:-/tmp}/migrate-legacy-cert-auth-test.XXXXXX"
}

write_fake_docker() {
    bin_dir=$1
    mkdir -p "${bin_dir}"

    cat > "${bin_dir}/docker" <<'EOF'
#!/bin/sh
set -eu

log_file="${PWD}/.docker-log"

if [ "${1:-}" != "compose" ]; then
    printf 'unexpected docker invocation: %s\n' "$*" >&2
    exit 1
fi
shift

while [ "$#" -gt 0 ]; do
    case "${1}" in
        --profile)
            [ "$#" -ge 2 ] || exit 1
            shift 2
            ;;
        version)
            printf 'compose version\n' >> "${log_file}"
            exit 0
            ;;
        run)
            printf 'run %s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >> "${log_file}"
            break
            ;;
        *)
            shift
            ;;
    esac
done

if [ "${1:-}" != "run" ] || [ "${2:-}" != "--rm" ] || [ "${3:-}" != "ocserv-auth" ] || [ "${4:-}" != "manage" ]; then
    printf 'unexpected docker compose run invocation: %s\n' "$*" >&2
    exit 1
fi

mkdir -p config/client-ca/private/issued-certs

while IFS=: read -r raw_user _; do
    user=$(printf '%s' "${raw_user}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "${user}" in
        ""|\#*)
            continue
            ;;
    esac
    if ! printf '%s\n' "${user}" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        continue
    fi

    user_dir="config/user-certs/${user}"
    issued_file="config/client-ca/private/issued-certs/${user}.pem"
    cert_file="${user_dir}/${user}-cert.pem"
    key_file="${user_dir}/${user}-key.pem"
    p12_file="${user_dir}/${user}.p12"
    ios_file="${user_dir}/ios-${user}.p12"

    mkdir -p "${user_dir}"

    if [ -f "${cert_file}" ]; then
        cp "${cert_file}" "${issued_file}"
        rm -f "${cert_file}" "${key_file}"
        continue
    fi

    [ -s "${p12_file}" ] || printf 'generated-p12\n' > "${p12_file}"
    [ -s "${ios_file}" ] || printf 'generated-ios-p12\n' > "${ios_file}"
    printf 'generated-issued-cert\n' > "${issued_file}"
done < config/auth/ocpasswd
EOF
    chmod +x "${bin_dir}/docker"
}

create_minimal_template() {
    template_file=$1
    cat > "${template_file}" <<'EOF'
auth = "plain[passwd=/etc/ocserv/auth/ocpasswd]"
#enable-auth = "certificate"
#ca-cert = /etc/ocserv/ca/ca-cert.pem
cert-user-oid = 0.9.2342.19200300.100.1.1
#crl = /etc/ocserv/ca/crl.pem
compression = false
max-clients = 32
server-cert = /etc/ocserv/fullchain.pem
server-key = /etc/ocserv/privkey.pem
EOF
}

create_project_tree() {
    base_dir=$1
    mkdir -p \
        "${base_dir}/scripts" \
        "${base_dir}/config/auth" \
        "${base_dir}/config/client-ca/public" \
        "${base_dir}/config/client-ca/private" \
        "${base_dir}/config/user-certs" \
        "${base_dir}/config/config-per-user" \
        "${base_dir}/backups"

    cp "${MIGRATE_SCRIPT}" "${base_dir}/scripts/migrate-legacy-cert-auth.sh"
    cp "${RENDER_SCRIPT}" "${base_dir}/scripts/render-ocserv-conf.sh"
    chmod +x "${base_dir}/scripts/migrate-legacy-cert-auth.sh" "${base_dir}/scripts/render-ocserv-conf.sh"

    create_minimal_template "${base_dir}/config/ocserv.conf.template"

    cat > "${base_dir}/.env" <<'EOF'
DOMAIN=vpn.example.com
OCSERV_ENABLE_CERT_AUTH=false
OCSERV_ENABLE_COMPRESSION=false
OCSERV_MAX_CLIENTS=32
EOF

    printf 'current-user:hash\n' > "${base_dir}/config/auth/ocpasswd"
    printf 'keep-me\n' > "${base_dir}/config/config-per-user/keep.conf"
}

create_legacy_tree_complete() {
    legacy_root=$1
    mkdir -p "${legacy_root}/ca" "${legacy_root}/user-certs/alice" "${legacy_root}/user-certs/bob"
    printf 'alice:hash\nbob:hash\n' > "${legacy_root}/ocpasswd"
    printf 'legacy-ca-cert\n' > "${legacy_root}/ca/ca-cert.pem"
    printf 'legacy-ca-key\n' > "${legacy_root}/ca/ca-key.pem"
    printf 'legacy-crl\n' > "${legacy_root}/ca/crl.pem"

    printf 'alice-cert\n' > "${legacy_root}/user-certs/alice/alice-cert.pem"
    printf 'alice-key\n' > "${legacy_root}/user-certs/alice/alice-key.pem"
    printf 'alice-p12\n' > "${legacy_root}/user-certs/alice/alice.p12"
    printf 'alice-ios\n' > "${legacy_root}/user-certs/alice/ios-alice.p12"

    printf 'bob-cert\n' > "${legacy_root}/user-certs/bob/bob-cert.pem"
    printf 'bob-key\n' > "${legacy_root}/user-certs/bob/bob-key.pem"
    printf 'bob-p12\n' > "${legacy_root}/user-certs/bob/bob.p12"
    printf 'bob-ios\n' > "${legacy_root}/user-certs/bob/ios-bob.p12"
}

create_legacy_tree_missing_pem() {
    legacy_root=$1
    create_legacy_tree_complete "${legacy_root}"
    rm -f "${legacy_root}/user-certs/bob/bob-cert.pem" "${legacy_root}/user-certs/bob/bob-key.pem"
}

run_migration() {
    project_dir=$1
    shift
    (
        CDPATH= cd -- "${project_dir}" && \
        PATH="${project_dir}/bin:${PATH}" \
        sh ./scripts/migrate-legacy-cert-auth.sh "$@"
    )
}

test_dry_run_does_not_modify_files() {
    base_dir=$(make_case_dir)
    trap 'rm -rf "${base_dir}"' EXIT HUP INT TERM
    create_project_tree "${base_dir}"
    mkdir -p "${base_dir}/bin"
    write_fake_docker "${base_dir}/bin"

    legacy_root="${base_dir}/legacy"
    create_legacy_tree_complete "${legacy_root}"

    original_env=$(cat "${base_dir}/.env")
    original_auth=$(cat "${base_dir}/config/auth/ocpasswd")

    output=$(run_migration "${base_dir}" --legacy-root "${legacy_root}" 2>&1)

    printf '%s\n' "${output}" | grep -q 'Dry-run only. No files were modified.' || fail "dry-run output missing completion message"
    [ "$(cat "${base_dir}/.env")" = "${original_env}" ] || fail ".env changed during dry-run"
    [ "$(cat "${base_dir}/config/auth/ocpasswd")" = "${original_auth}" ] || fail "auth file changed during dry-run"
    [ ! -e "${base_dir}/config/ocserv.conf" ] || fail "ocserv.conf should not be rendered during dry-run"

    rm -rf "${base_dir}"
    trap - EXIT HUP INT TERM
}

test_apply_migrates_complete_legacy_tree() {
    base_dir=$(make_case_dir)
    trap 'rm -rf "${base_dir}"' EXIT HUP INT TERM
    create_project_tree "${base_dir}"
    mkdir -p "${base_dir}/bin"
    write_fake_docker "${base_dir}/bin"

    legacy_root="${base_dir}/legacy"
    backup_dir="${base_dir}/custom-backup"
    create_legacy_tree_complete "${legacy_root}"

    output=$(run_migration "${base_dir}" --legacy-root "${legacy_root}" --backup-dir "${backup_dir}" --apply 2>&1)

    [ -d "${backup_dir}/config/auth" ] || fail "backup missing config/auth"
    [ -f "${backup_dir}/.env" ] || fail "backup missing .env"
    [ "$(cat "${base_dir}/config/auth/ocpasswd")" = "$(cat "${legacy_root}/ocpasswd")" ] || fail "auth file did not migrate"
    [ "$(cat "${base_dir}/config/client-ca/public/ca-cert.pem")" = "legacy-ca-cert" ] || fail "CA cert did not migrate"
    [ "$(cat "${base_dir}/config/client-ca/public/crl.pem")" = "legacy-crl" ] || fail "CRL did not migrate"
    [ "$(cat "${base_dir}/config/client-ca/private/ca-key.pem")" = "legacy-ca-key" ] || fail "CA key did not migrate"
    [ -f "${base_dir}/config/client-ca/private/issued-certs/alice.pem" ] || fail "alice issued cert missing"
    [ -f "${base_dir}/config/client-ca/private/issued-certs/bob.pem" ] || fail "bob issued cert missing"
    [ ! -e "${base_dir}/config/user-certs/alice/alice-cert.pem" ] || fail "alice legacy cert not removed"
    [ ! -e "${base_dir}/config/user-certs/alice/alice-key.pem" ] || fail "alice legacy key not removed"
    [ ! -e "${base_dir}/config/user-certs/bob/bob-cert.pem" ] || fail "bob legacy cert not removed"
    [ ! -e "${base_dir}/config/user-certs/bob/bob-key.pem" ] || fail "bob legacy key not removed"
    [ -s "${base_dir}/config/user-certs/alice/alice.p12" ] || fail "alice p12 missing"
    [ -s "${base_dir}/config/user-certs/alice/ios-alice.p12" ] || fail "alice ios p12 missing"
    [ -s "${base_dir}/config/user-certs/bob/bob.p12" ] || fail "bob p12 missing"
    [ -s "${base_dir}/config/user-certs/bob/ios-bob.p12" ] || fail "bob ios p12 missing"
    [ -f "${base_dir}/config/config-per-user/keep.conf" ] || fail "existing config-per-user file should be preserved"
    grep -Fqx 'OCSERV_ENABLE_CERT_AUTH=true' "${base_dir}/.env" || fail ".env did not enable certificate auth"
    grep -Fqx 'enable-auth = "certificate"' "${base_dir}/config/ocserv.conf" || fail "rendered config missing enable-auth"
    grep -Fqx 'ca-cert = /etc/ocserv/ca/ca-cert.pem' "${base_dir}/config/ocserv.conf" || fail "rendered config missing ca-cert"
    grep -Fqx 'crl = /etc/ocserv/ca/crl.pem' "${base_dir}/config/ocserv.conf" || fail "rendered config missing crl"
    printf '%s\n' "${output}" | grep -q "Backup directory: ${backup_dir}" || fail "output missing backup directory"
    printf '%s\n' "${output}" | grep -q 'Manual restore instructions:' || fail "output missing restore instructions"
    printf '%s\n' "${output}" | grep -q 'docker compose --profile tools run --rm ocserv-auth status' || fail "output missing runtime check command"
    ! grep -q 'build ocserv-auth' "${base_dir}/.docker-log" || fail "docker build should not be invoked"
    grep -q 'run --rm ocserv-auth manage' "${base_dir}/.docker-log" || fail "docker manage was not invoked"

    rm -rf "${base_dir}"
    trap - EXIT HUP INT TERM
}

test_apply_warns_and_reissues_when_pem_is_missing() {
    base_dir=$(make_case_dir)
    trap 'rm -rf "${base_dir}"' EXIT HUP INT TERM
    create_project_tree "${base_dir}"
    mkdir -p "${base_dir}/bin"
    write_fake_docker "${base_dir}/bin"

    legacy_root="${base_dir}/legacy"
    create_legacy_tree_missing_pem "${legacy_root}"

    output=$(run_migration "${base_dir}" --legacy-root "${legacy_root}" --apply 2>&1)

    printf '%s\n' "${output}" | grep -q '\[bob\] missing bob-cert.pem; manage will treat this user as missing a certificate and reissue artifacts' \
        || fail "missing PEM warning not reported"
    [ -s "${base_dir}/config/client-ca/private/issued-certs/bob.pem" ] || fail "bob issued cert was not reissued"
    [ -s "${base_dir}/config/user-certs/bob/bob.p12" ] || fail "bob p12 missing after reissue"
    [ -s "${base_dir}/config/user-certs/bob/ios-bob.p12" ] || fail "bob ios p12 missing after reissue"

    rm -rf "${base_dir}"
    trap - EXIT HUP INT TERM
}

test_preflight_failure_happens_before_mutation() {
    base_dir=$(make_case_dir)
    trap 'rm -rf "${base_dir}"' EXIT HUP INT TERM
    create_project_tree "${base_dir}"
    mkdir -p "${base_dir}/bin"
    write_fake_docker "${base_dir}/bin"

    legacy_root="${base_dir}/legacy"
    backup_dir="${base_dir}/should-not-exist"
    create_legacy_tree_complete "${legacy_root}"
    rm -f "${legacy_root}/ca/ca-key.pem"

    original_auth=$(cat "${base_dir}/config/auth/ocpasswd")
    if run_migration "${base_dir}" --legacy-root "${legacy_root}" --backup-dir "${backup_dir}" --apply >/dev/null 2>&1; then
        fail "migration unexpectedly succeeded without ca-key.pem"
    fi

    [ "$(cat "${base_dir}/config/auth/ocpasswd")" = "${original_auth}" ] || fail "target auth file changed after failed preflight"
    [ ! -e "${backup_dir}" ] || fail "backup directory should not be created on preflight failure"

    rm -rf "${base_dir}"
    trap - EXIT HUP INT TERM
}

test_dry_run_does_not_modify_files
test_apply_migrates_complete_legacy_tree
test_apply_warns_and_reissues_when_pem_is_missing
test_preflight_failure_happens_before_mutation

printf 'legacy certificate migration tests passed\n'
