#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="${ROOT_DIR}/scripts/ocserv-cert-auth.sh"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

normalize_serial() {
    serial=${1-}
    serial=$(printf '%s' "$serial" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]:')
    case "$serial" in
        0X*) serial=${serial#0X} ;;
    esac
    serial=$(printf '%s' "$serial" | sed 's/^0*//')
    [ -n "$serial" ] || serial=0
    printf '%s\n' "$serial"
}

crl_serials() {
    crl_file=$1
    openssl crl -in "$crl_file" -noout -text |
        awk '/Revoked Certificates:/,/Signature Algorithm:/ {
            if ($0 ~ /Serial Number:/) {
                print $NF
            }
        }' |
        while IFS= read -r serial; do
            normalize_serial "$serial"
        done
}

crl_contains_serial() {
    crl_file=$1
    serial=$2
    target=$(normalize_serial "$serial")
    parsed=$(crl_serials "$crl_file" || true)
    printf '%s\n' "$parsed" | grep -qx "$target"
}

assert_crl_contains_serial() {
    crl_file=$1
    serial=$2
    message=$3
    target=$(normalize_serial "$serial")
    parsed=$(crl_serials "$crl_file" || true)
    if ! printf '%s\n' "$parsed" | grep -qx "$target"; then
        parsed_list=$(printf '%s' "$parsed" | tr '\n' ',' | sed 's/,$//')
        fail "$message (target serial=$target, parsed serials=${parsed_list:-<empty>})"
    fi
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
ISSUED_CERT_DIR="${CA_PRIVATE_DIR}/issued-certs"
REVOKED_METADATA_DIR="${CA_PRIVATE_DIR}/revoked-metadata"
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

run_tool_with_path_prefix() {
    path_prefix=$1
    shift
    PATH="${path_prefix}:${BIN_DIR}:${PATH}" \
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
    for candidate in "${CA_PRIVATE_DIR}/.old-issued-${user}."*; do
        if [ -e "${candidate}" ]; then
            fail "reissue left an issued certificate backup behind: ${candidate}"
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
[ -s "${USER_CERT_DIR}/alice/alice.p12" ] || fail "alice p12 was not generated"
[ -s "${USER_CERT_DIR}/alice/ios-alice.p12" ] || fail "alice iOS p12 was not generated"
[ ! -e "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "alice certificate pem was left in user directory"
[ ! -e "${USER_CERT_DIR}/alice/alice-key.pem" ] || fail "alice private key pem was left in user directory"
[ -s "${ISSUED_CERT_DIR}/alice.pem" ] || fail "alice issued certificate was not indexed"

status_output=$(run_tool status 2>&1)
echo "$status_output" | grep -q '^alice[[:space:]]*valid' || fail "alice status is not valid"
echo "$status_output" | grep -Eq '^alice[[:space:]]*valid[[:space:]]*expires [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \([0-9]+ days left\)$' || fail "alice status did not include expiry detail"
CA_CERT_BACKUP="${BASE_DIR}/ca-cert-backup.pem"
cp "${CA_PUBLIC_DIR}/ca-cert.pem" "${CA_CERT_BACKUP}"

VERIFY_FAIL_BIN_DIR="${BASE_DIR}/verify-fail-bin"
mkdir -p "${VERIFY_FAIL_BIN_DIR}"
cat > "${VERIFY_FAIL_BIN_DIR}/openssl" <<EOF
#!/bin/sh
if [ "\$1" = "verify" ]; then
    printf '%s\n' 'CN = forced verify failure' >&2
    printf '%s\n' 'error 20 at 0 depth lookup: unable to get local issuer certificate' >&2
    exit 2
fi
exec "${REAL_OPENSSL}" "\$@"
EOF
chmod +x "${VERIFY_FAIL_BIN_DIR}/openssl"
status_output=$(run_tool_with_path_prefix "${VERIFY_FAIL_BIN_DIR}" status 2>&1)
echo "$status_output" | grep -q '^alice[[:space:]]*invalid-chain' || fail "alice status did not downgrade on verify failure"
echo "$status_output" | grep -q 'unable to get local issuer certificate' || fail "status did not surface verify failure reason"

bob_serial=$(normalize_serial "$(openssl x509 -in "${ISSUED_CERT_DIR}/bob.pem" -noout -serial | sed 's/^serial=//')")
if run_tool reissue bob >/dev/null 2>&1; then
    fail "reissue unexpectedly succeeded for non-revoked bob"
fi
[ -s "${ISSUED_CERT_DIR}/bob.pem" ] || fail "bob issued certificate was removed by failed reissue"
bob_serial_after=$(normalize_serial "$(openssl x509 -in "${ISSUED_CERT_DIR}/bob.pem" -noout -serial | sed 's/^serial=//')")
[ "${bob_serial}" = "${bob_serial_after}" ] || fail "failed bob reissue changed certificate serial"

mv "${ISSUED_CERT_DIR}/bob.pem" "${USER_CERT_DIR}/bob/bob-cert.pem"
printf 'legacy-key\n' > "${USER_CERT_DIR}/bob/bob-key.pem"
status_output=$(run_tool status 2>&1)
echo "$status_output" | grep -q '^bob[[:space:]]*valid' || fail "legacy bob status is not valid"
[ ! -e "${ISSUED_CERT_DIR}/bob.pem" ] || fail "status migrated legacy bob certificate unexpectedly"
run_tool manage >/dev/null
[ -s "${ISSUED_CERT_DIR}/bob.pem" ] || fail "manage did not migrate bob issued certificate"
[ ! -e "${USER_CERT_DIR}/bob/bob-cert.pem" ] || fail "manage did not remove legacy bob certificate"
[ ! -e "${USER_CERT_DIR}/bob/bob-key.pem" ] || fail "manage did not remove legacy bob private key"

rm -f "${USER_CERT_DIR}/bob/ios-bob.p12"
status_output=$(run_tool status 2>&1)
echo "$status_output" | grep -q '^bob[[:space:]]*artifact-missing' || fail "bob status did not report missing p12 artifact"
status_output=$(run_tool_with_path_prefix "${VERIFY_FAIL_BIN_DIR}" status 2>&1)
echo "$status_output" | grep -q '^bob[[:space:]]*artifact-missing' || fail "artifact-missing status lost precedence over verify failure"

printf 'not a certificate\n' > "${CA_PUBLIC_DIR}/ca-cert.pem"
status_output=$(run_tool status 2>&1)
echo "$status_output" | grep -q 'ca-invalid' || fail "status did not report unreadable CA"
echo "$status_output" | grep -q '^alice[[:space:]]*invalid-chain' || fail "alice status did not downgrade on unreadable CA"
echo "$status_output" | grep -q '^bob[[:space:]]*artifact-missing' || fail "artifact-missing status lost precedence over unreadable CA"
cp "${CA_CERT_BACKUP}" "${CA_PUBLIC_DIR}/ca-cert.pem"

EXPIRED_CA_BIN_DIR="${BASE_DIR}/expired-ca-bin"
mkdir -p "${EXPIRED_CA_BIN_DIR}"
cat > "${EXPIRED_CA_BIN_DIR}/openssl" <<EOF
#!/bin/sh
if [ "\$1" = "x509" ] && [ "\$2" = "-in" ] && [ "\$3" = "${CA_PUBLIC_DIR}/ca-cert.pem" ] && [ "\$4" = "-noout" ] && [ "\$5" = "-enddate" ]; then
    printf 'notAfter=Jan  1 00:00:00 2000 GMT\n'
    exit 0
fi
exec "${REAL_OPENSSL}" "\$@"
EOF
chmod +x "${EXPIRED_CA_BIN_DIR}/openssl"
status_output=$(run_tool_with_path_prefix "${EXPIRED_CA_BIN_DIR}" status 2>&1)
echo "$status_output" | grep -q 'ca-expired' || fail "status did not report expired CA"
echo "$status_output" | grep -q '^alice[[:space:]]*invalid-chain' || fail "alice status did not downgrade on expired CA"
echo "$status_output" | grep -q 'issuing CA certificate expired 2000-01-01T00:00:00Z' || fail "status did not include expired CA detail"
echo "$status_output" | grep -q '^bob[[:space:]]*artifact-missing' || fail "artifact-missing status lost precedence over expired CA"
run_tool manage >/dev/null
[ ! -e "${USER_CERT_DIR}/bob/ios-bob.p12" ] || fail "manage unexpectedly regenerated missing bob p12 artifact"

old_serial=$(normalize_serial "$(openssl x509 -in "${ISSUED_CERT_DIR}/alice.pem" -noout -serial | sed 's/^serial=//')")
if printf 'wrong-user\n' | run_tool revoke alice >/dev/null 2>&1; then
    fail "revoke unexpectedly succeeded with incorrect confirmation"
fi
[ -s "${ISSUED_CERT_DIR}/alice.pem" ] || fail "alice issued certificate was removed after cancelled revoke"
[ ! -e "${CA_PRIVATE_DIR}/disabled-users/alice" ] || fail "disabled marker was written after cancelled revoke"
if crl_contains_serial "${CA_PUBLIC_DIR}/crl.pem" "${old_serial}"; then
    fail "cancelled revoke added alice serial to CRL"
fi

printf 'bob\n' | run_tool revoke bob >/dev/null
[ ! -e "${ISSUED_CERT_DIR}/bob.pem" ] || fail "bob issued certificate was not removed after confirmed revoke"
[ ! -e "${USER_CERT_DIR}/bob/bob.p12" ] || fail "bob p12 was not removed after confirmed revoke"
[ -s "${CA_PRIVATE_DIR}/disabled-users/bob" ] || fail "bob disabled marker was not written"
[ -s "${REVOKED_METADATA_DIR}/bob-${bob_serial}.env" ] || fail "bob revoked metadata was not written"
assert_crl_contains_serial "${CA_PUBLIC_DIR}/crl.pem" "${bob_serial}" "bob serial is not listed in CRL after confirmed revoke"

run_tool revoke --yes alice >/dev/null

[ ! -e "${ISSUED_CERT_DIR}/alice.pem" ] || fail "revoked alice issued certificate was not removed"
[ ! -e "${USER_CERT_DIR}/alice/alice.p12" ] || fail "revoked alice p12 was not removed"
[ -s "${CA_PRIVATE_DIR}/disabled-users/alice" ] || fail "disabled marker was not written"
[ -s "${REVOKED_METADATA_DIR}/alice-${old_serial}.env" ] || fail "alice revoked metadata was not written"
openssl crl -in "${CA_PUBLIC_DIR}/crl.pem" -noout -text | grep -q 'Revoked Certificates' || fail "CRL does not contain revoked certificates"
assert_crl_contains_serial "${CA_PUBLIC_DIR}/crl.pem" "${old_serial}" "old serial is not listed in CRL"

status_output=$(run_tool status 2>&1)
echo "$status_output" | grep -q '^alice[[:space:]]*revoked' || fail "alice status is not revoked"
status_output=$(run_tool_with_path_prefix "${VERIFY_FAIL_BIN_DIR}" status 2>&1)
echo "$status_output" | grep -q '^alice[[:space:]]*revoked' || fail "revoked status lost precedence over verify failure"
run_tool manage >/dev/null
[ ! -e "${ISSUED_CERT_DIR}/alice.pem" ] || fail "manage reissued a revoked user unexpectedly"

run_tool revoke --yes alice >/dev/null
[ ! -e "${ISSUED_CERT_DIR}/alice.pem" ] || fail "repeated revoke changed revoked user state unexpectedly"

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
[ ! -e "${ISSUED_CERT_DIR}/alice.pem" ] || fail "manage reissued alice after failed reissue"

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
[ ! -e "${ISSUED_CERT_DIR}/alice.pem" ] || fail "marker removal failure left a usable alice certificate"
[ ! -e "${USER_CERT_DIR}/alice/alice.p12" ] || fail "marker removal failure left a usable alice p12"
assert_no_reissue_leftovers alice
run_tool manage >/dev/null
[ ! -e "${ISSUED_CERT_DIR}/alice.pem" ] || fail "manage reissued alice after marker removal failure"

run_tool reissue alice >/dev/null
[ -s "${USER_CERT_DIR}/alice/alice.p12" ] || fail "alice p12 was not reissued"
[ -s "${USER_CERT_DIR}/alice/ios-alice.p12" ] || fail "alice iOS p12 was not reissued"
[ ! -e "${USER_CERT_DIR}/alice/alice-cert.pem" ] || fail "alice certificate pem was left in user directory after reissue"
[ ! -e "${USER_CERT_DIR}/alice/alice-key.pem" ] || fail "alice private key pem was left in user directory after reissue"
[ -s "${ISSUED_CERT_DIR}/alice.pem" ] || fail "alice issued certificate was not reissued"
[ ! -e "${CA_PRIVATE_DIR}/disabled-users/alice" ] || fail "disabled marker was not cleared by reissue"
new_serial=$(normalize_serial "$(openssl x509 -in "${ISSUED_CERT_DIR}/alice.pem" -noout -serial | sed 's/^serial=//')")
[ "${old_serial}" != "${new_serial}" ] || fail "reissue reused old certificate serial"
assert_crl_contains_serial "${CA_PUBLIC_DIR}/crl.pem" "${old_serial}" "old serial disappeared from CRL after reissue"

printf 'ocserv certificate auth tests passed\n'
