#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ENTRYPOINT="${ROOT_DIR}/nginx/docker-entrypoint.sh"
TEMPLATE="${ROOT_DIR}/nginx/templates/monitoring-subpath.conf.template"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

make_case_dir() {
    mktemp -d "${TMPDIR:-/tmp}/nginx-entrypoint-test.XXXXXX"
}

write_stubs() {
    bin_dir=$1
    mkdir -p "${bin_dir}"

    cat > "${bin_dir}/envsubst" <<'EOF'
#!/bin/sh
sed "s|\${DOMAIN}|${DOMAIN}|g; s|\${MONITORING_PORT}|${MONITORING_PORT}|g"
EOF
    chmod +x "${bin_dir}/envsubst"

    cat > "${bin_dir}/nginx" <<'EOF'
#!/bin/sh
case "${1:-}" in
    -t|-g) exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${bin_dir}/nginx"
}

prepare_success_tree() {
    base_dir=$1
    mkdir -p \
        "${base_dir}/templates" \
        "${base_dir}/conf.d" \
        "${base_dir}/snippets" \
        "${base_dir}/letsencrypt/live/vpn.example.com"

    cp "${TEMPLATE}" "${base_dir}/templates/monitoring-subpath.conf.template"
    printf 'ssl_protocols TLSv1.2 TLSv1.3;\n' > "${base_dir}/snippets/ssl-params.conf"
    printf 'cert\n' > "${base_dir}/letsencrypt/live/vpn.example.com/fullchain.pem"
    printf 'key\n' > "${base_dir}/letsencrypt/live/vpn.example.com/privkey.pem"
}

run_entrypoint() {
    base_dir=$1
    shift
    PATH="${base_dir}/bin:${PATH}" \
    TEMPLATE_DIR="${base_dir}/templates" \
    CONF_DIR="${base_dir}/conf.d" \
    SNIPPET_FILE="${base_dir}/snippets/ssl-params.conf" \
    LETSENCRYPT_LIVE_DIR="${base_dir}/letsencrypt/live" \
    DOMAIN="${DOMAIN:-vpn.example.com}" \
    MONITORING_PORT="${MONITORING_PORT:-8443}" \
    "$@" sh "${ENTRYPOINT}"
}

test_success_renders_grafana_only() {
    base_dir=$(make_case_dir)
    trap 'rm -rf "${base_dir}"' EXIT HUP INT TERM
    write_stubs "${base_dir}/bin"
    prepare_success_tree "${base_dir}"

    run_entrypoint "${base_dir}" env >/dev/null

    output="${base_dir}/conf.d/monitoring-subpath.conf"
    [ -f "${output}" ] || fail "rendered nginx config missing"
    grep -q 'server_name vpn.example.com;' "${output}" || fail "domain was not rendered"
    grep -q 'location /grafana/' "${output}" || fail "grafana location missing"
    ! grep -q '\${DOMAIN}' "${output}" || fail "DOMAIN placeholder was not rendered"
    ! grep -q 'location /prometheus/' "${output}" || fail "prometheus should not be externally proxied"

    rm -rf "${base_dir}"
    trap - EXIT HUP INT TERM
}

test_invalid_domain_fails() {
    base_dir=$(make_case_dir)
    trap 'rm -rf "${base_dir}"' EXIT HUP INT TERM
    write_stubs "${base_dir}/bin"
    prepare_success_tree "${base_dir}"

    if DOMAIN='bad/domain' run_entrypoint "${base_dir}" env >/dev/null 2>&1; then
        fail "invalid domain unexpectedly passed"
    fi

    rm -rf "${base_dir}"
    trap - EXIT HUP INT TERM
}

test_invalid_port_fails() {
    base_dir=$(make_case_dir)
    trap 'rm -rf "${base_dir}"' EXIT HUP INT TERM
    write_stubs "${base_dir}/bin"
    prepare_success_tree "${base_dir}"

    if MONITORING_PORT='70000' run_entrypoint "${base_dir}" env >/dev/null 2>&1; then
        fail "invalid port unexpectedly passed"
    fi

    rm -rf "${base_dir}"
    trap - EXIT HUP INT TERM
}

test_missing_cert_fails() {
    base_dir=$(make_case_dir)
    trap 'rm -rf "${base_dir}"' EXIT HUP INT TERM
    write_stubs "${base_dir}/bin"
    prepare_success_tree "${base_dir}"
    rm -f "${base_dir}/letsencrypt/live/vpn.example.com/fullchain.pem"

    if run_entrypoint "${base_dir}" env >/dev/null 2>&1; then
        fail "missing certificate unexpectedly passed"
    fi

    rm -rf "${base_dir}"
    trap - EXIT HUP INT TERM
}

test_success_renders_grafana_only
test_invalid_domain_fails
test_invalid_port_fails
test_missing_cert_fails

printf 'nginx entrypoint tests passed\n'
