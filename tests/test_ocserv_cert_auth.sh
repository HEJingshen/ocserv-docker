#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="${ROOT_DIR}/scripts/ocserv-cert-auth.sh"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v certtool >/dev/null 2>&1 || {
    printf 'certtool not found; skipping ocserv certificate auth integration test\n'
    exit 0
}
CERTTOOL_HELP=$(certtool --help 2>&1 || true)
printf '%s\n' "${CERTTOOL_HELP}" | grep -q -- '--generate-self-signed' &&
    printf '%s\n' "${CERTTOOL_HELP}" | grep -q -- '--generate-certificate' &&
    printf '%s\n' "${CERTTOOL_HELP}" | grep -q -- '--generate-crl' || {
    printf 'GnuTLS certtool certificate generation support not found; skipping ocserv certificate auth integration test\n'
    exit 0
}
command -v openssl >/dev/null 2>&1 || {
    printf 'openssl not found; skipping ocserv certificate auth integration test\n'
    exit 0
}
REAL_OPENSSL=$(command -v openssl)
REAL_RM=$(command -v rm)

BASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ocserv-cert-auth-test.XXXXXX")
trap 'rm -rf "${BASE_DIR}"' EXIT HUP INT TERM

BIN_DIR="${BASE_DIR}/bin"
AUTH_DIR="${BASE_DIR}/auth"
CA_PUBLIC_DIR="${BASE_DIR}/client-ca/public"
CA_PRIVATE_DIR="${BASE_DIR}/client-ca/private"
USER_CERT_DIR="${BASE_DIR}/user-certs"
CONFIG_PER_USER_DIR="${BASE_DIR}/config-per-user"
LOCK_FILE="${BASE_DIR}/lock/ocserv-cert-auth.lock"

mkdir -p "${BIN_DIR}" "${AUTH_DIR}" "${CA_PUBLIC_DIR}" "${CA_PRIVATE_DIR}" "${USER_CERT_DIR}" "${CONFIG_PER_USER_DIR}" "$(dirname "${LOCK_FILE}")"
touch "${AUTH_DIR}/empty"

if ! command -v flock >/dev/null 2>&1; then
    cat > "${BIN_DIR}/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${BIN_DIR}/flock"
fi

run_tool() {
    PATH="${BIN_DIR}:${PATH}" \
    OCPASSWD="${AUTH_DIR}/ocpasswd" \
    CA_PUBLIC_DIR="${CA_PUBLIC_DIR}" \
    CA_PRIVATE_DIR="${CA_PRIVATE_DIR}" \
    CERT_DIR="${USER_CERT_DIR}" \
    CONFIG_PER_USER_DIR="${CONFIG_PER_USER_DIR}" \
    LOCK_FILE="${LOCK_FILE}" \
    ALLOW_EMPTY_P12_PASSWORD=true \
    bash "${SCRIPT}" "$@"
}

assert_no_reissue_leftovers() {
    user=$1
    for candidate in "${USER_CERT_DIR}/.tmp-${user}."* "${USER_CERT_DIR}/.old-${user}."*; do
        if [ -d "${candidate}" ]; then
            fail "reissue left a temporary directory behind: ${candidate}"
        fi
    done
}

if OCPASSWD="${AUTH_DIR}/empty" \
    CA_PUBLIC_DIR="${CA_PUBLIC_DIR}" \
    CA_PRIVATE_DIR="${CA_PRIVATE_DIR}" \
    CERT_DIR="${USER_CERT_DIR}" \
    CONFIG_PER_USER_DIR="${CONFIG_PER_USER_DIR}" \
    LOCK_FILE="${LOCK_FILE}" \
    ALLOW_EMPTY_P12_PASSWORD=true \
    PATH="${BIN_DIR}:${PATH}" \
    bash "${SCRIPT}" status >/dev/null 2>&1; then
    fail "empty ocpasswd unexpectedly passed"
fi

printf 'alice:group:hash\nbob:hash\n' > "${AUTH_DIR}/ocpasswd"

status_output=$(run_tool status 2>&1)
echo "$status_output" | grep -q 'ca-missing' || fail "status did not report missing CA"
[ ! -e "${CA_PUBLIC_DIR}/ca-cert.pem" ] || fail "status unexpectedly created CA certificate"
[ ! -e "${CA_PRIVATE_DIR}/ca-key.pem" ] || fail "status unexpectedly created CA private key"

run_tool init-ca >/dev/null
[ -s "${CA_PUBLIC_DIR}/ca-cert.pem" ] || fail "CA certificate was not initialized"
[ -s "${CA_PUBLIC_DIR}/crl.pem" ] || fail "CRL was not initialized"

run_tool manage >/dev/null

[ -s "${CA_PUBLIC_DIR}/ca-cert.pem" ] || fail "CA certificate was not generated"
[ -s "${CA_PUBLIC_DIR}/crl.pem" ] || fail "CRL was not generated"
[ -s "${CA_PRIVATE_DIR}/ca-key.pem" ] || fail "CA private key was not generated"
[ -s "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "alice certificate was not generated"
[ -s "${USER_CERT_DIR}/alice/alice.p12" ] || fail "alice p12 was not generated"
[ -s "${USER_CERT_DIR}/alice/ios-alice.p12" ] || fail "alice iOS p12 was not generated"

status_output=$(run_tool status 2>&1)
echo "$status_output" | grep -q '^alice[[:space:]]*valid' || fail "alice status is not valid"
bob_serial=$(openssl x509 -in "${USER_CERT_DIR}/bob/bob-cert.pem" -noout -serial | sed 's/^serial=//')
if run_tool reissue bob >/dev/null 2>&1; then
    fail "reissue unexpectedly succeeded for non-revoked bob"
fi
[ -s "${USER_CERT_DIR}/bob/bob-cert.pem" ] || fail "bob certificate was removed by failed reissue"
bob_serial_after=$(openssl x509 -in "${USER_CERT_DIR}/bob/bob-cert.pem" -noout -serial | sed 's/^serial=//')
[ "${bob_serial}" = "${bob_serial_after}" ] || fail "failed bob reissue changed certificate serial"

old_serial=$(openssl x509 -in "${USER_CERT_DIR}/alice/alice-cert.pem" -noout -serial | sed 's/^serial=//')
run_tool revoke alice >/dev/null

[ ! -e "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "revoked alice certificate was not removed"
[ -s "${CA_PRIVATE_DIR}/disabled-users/alice" ] || fail "disabled marker was not written"
find "${USER_CERT_DIR}/revoked-archive" -type f -name 'alice-cert.pem' | grep -q . || fail "revoked alice certificate was not archived"
openssl crl -in "${CA_PUBLIC_DIR}/crl.pem" -noout -text | grep -q 'Revoked Certificates' || fail "CRL does not contain revoked certificates"
openssl crl -in "${CA_PUBLIC_DIR}/crl.pem" -noout -text | grep -qi "${old_serial}" || fail "old serial is not listed in CRL"

status_output=$(run_tool status 2>&1)
echo "$status_output" | grep -q '^alice[[:space:]]*revoked' || fail "alice status is not revoked"
run_tool manage >/dev/null
[ ! -e "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "manage reissued a revoked user unexpectedly"

run_tool revoke alice >/dev/null
[ ! -e "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "repeated revoke changed revoked user state unexpectedly"

FAIL_BIN_DIR="${BASE_DIR}/fail-bin"
mkdir -p "${FAIL_BIN_DIR}"
cat > "${FAIL_BIN_DIR}/openssl" <<EOF
#!/bin/sh
case "\$1 \$2" in
    "version "*) exec "${REAL_OPENSSL}" "\$@" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${FAIL_BIN_DIR}/openssl"
if PATH="${FAIL_BIN_DIR}:${BIN_DIR}:${PATH}" \
    OCPASSWD="${AUTH_DIR}/ocpasswd" \
    CA_PUBLIC_DIR="${CA_PUBLIC_DIR}" \
    CA_PRIVATE_DIR="${CA_PRIVATE_DIR}" \
    CERT_DIR="${USER_CERT_DIR}" \
    CONFIG_PER_USER_DIR="${CONFIG_PER_USER_DIR}" \
    LOCK_FILE="${LOCK_FILE}" \
    ALLOW_EMPTY_P12_PASSWORD=true \
    bash "${SCRIPT}" reissue alice >/dev/null 2>&1; then
    fail "reissue unexpectedly succeeded with failing openssl"
fi
[ -s "${CA_PRIVATE_DIR}/disabled-users/alice" ] || fail "disabled marker was removed after failed reissue"
assert_no_reissue_leftovers alice
run_tool manage >/dev/null
[ ! -e "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "manage reissued alice after failed reissue"

MARKER_FAIL_BIN_DIR="${BASE_DIR}/marker-fail-bin"
mkdir -p "${MARKER_FAIL_BIN_DIR}"
cat > "${MARKER_FAIL_BIN_DIR}/rm" <<EOF
#!/bin/sh
if [ "\$1" = "-f" ] && [ "\$2" = "${CA_PRIVATE_DIR}/disabled-users/alice" ]; then
    exit 1
fi
exec "${REAL_RM}" "\$@"
EOF
chmod +x "${MARKER_FAIL_BIN_DIR}/rm"
if PATH="${MARKER_FAIL_BIN_DIR}:${BIN_DIR}:${PATH}" \
    OCPASSWD="${AUTH_DIR}/ocpasswd" \
    CA_PUBLIC_DIR="${CA_PUBLIC_DIR}" \
    CA_PRIVATE_DIR="${CA_PRIVATE_DIR}" \
    CERT_DIR="${USER_CERT_DIR}" \
    CONFIG_PER_USER_DIR="${CONFIG_PER_USER_DIR}" \
    LOCK_FILE="${LOCK_FILE}" \
    ALLOW_EMPTY_P12_PASSWORD=true \
    bash "${SCRIPT}" reissue alice >/dev/null 2>&1; then
    fail "reissue unexpectedly succeeded when disabled marker removal failed"
fi
[ -s "${CA_PRIVATE_DIR}/disabled-users/alice" ] || fail "disabled marker was removed after marker removal failure"
[ ! -e "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "marker removal failure left a usable alice certificate"
assert_no_reissue_leftovers alice
run_tool manage >/dev/null
[ ! -e "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "manage reissued alice after marker removal failure"

run_tool reissue alice >/dev/null
[ -s "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "alice certificate was not reissued"
[ ! -e "${CA_PRIVATE_DIR}/disabled-users/alice" ] || fail "disabled marker was not cleared by reissue"
new_serial=$(openssl x509 -in "${USER_CERT_DIR}/alice/alice-cert.pem" -noout -serial | sed 's/^serial=//')
[ "${old_serial}" != "${new_serial}" ] || fail "reissue reused old certificate serial"
openssl crl -in "${CA_PUBLIC_DIR}/crl.pem" -noout -text | grep -qi "${old_serial}" || fail "old serial disappeared from CRL after reissue"

printf 'ocserv certificate auth tests passed\n'
