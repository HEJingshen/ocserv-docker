# common.sh - Shared utilities for ocserv-docker scripts
# Usage: set SCRIPT_DIR first, then source this file.
#   SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
#   . "${SCRIPT_DIR}/common.sh"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# shellcheck disable=SC2034
PROJECT_ROOT=$(
    unset CDPATH
    cd -- "${SCRIPT_DIR}/.." && pwd
)

# Read a key from a Docker-style .env file without executing it.
env_file_value() {
    _efv_file=$1
    _efv_key=$2

    awk -v key="${_efv_key}" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                value = line
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
                sub(/[[:space:]]+#.*$/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) {
                    value = substr(value, 2, length(value) - 2)
                }
            }
        }
        END { print value }
    ' "${_efv_file}"
}

# Validate that EDITOR points to an executable command. Arguments are allowed.
validate_editor_command() {
    _vec_cmd=$1

    # shellcheck disable=SC2086
    set -- ${_vec_cmd}
    [ "$#" -gt 0 ] || fail "editor command is empty"
    command -v "$1" >/dev/null 2>&1 || fail "editor command not found: $1"
}

# Run EDITOR with optional arguments against the supplied file.
run_editor_command() {
    _rec_cmd=$1
    _rec_file=$2

    # shellcheck disable=SC2086
    set -- ${_rec_cmd}
    "$@" "${_rec_file}"
}

# Validate that a required path points to an existing regular file.
validate_regular_file() {
    _vrf_name=$1
    _vrf_path=$2

    [ -n "${_vrf_path}" ] || fail "${_vrf_name} is empty"
    [ -f "${_vrf_path}" ] || fail "${_vrf_name} must point to an existing regular file: ${_vrf_path}"
}

# Validate that DOMAIN is a real domain: non-empty, not placeholder, valid FQDN.
validate_domain() {
    _vd_name=$1
    _vd_value=$2

    [ -n "${_vd_value}" ] || fail "${_vd_name} is empty"
    validate_fqdn "${_vd_name}" "${_vd_value}"
    case "${_vd_value}" in
        your.domain.com)
            fail "${_vd_name} is still set to the placeholder value 'your.domain.com'"
            ;;
    esac
}

# Validate that TLS certificate and key paths point to existing regular files.
validate_tls_paths() {
    _vtl_cert=$1
    _vtl_key=$2

    validate_regular_file TLS_CERT_FILE "${_vtl_cert}"
    validate_regular_file TLS_KEY_FILE "${_vtl_key}"
}

# Validate that a value is a boolean (true or false).
validate_bool() {
    case "$2" in
        true|false) ;;
        *) fail "$1 must be true or false: $2" ;;
    esac
}

# Validate that a value is a valid FQDN (RFC 1035).
validate_fqdn() {
    _vf_name=$1
    _vf_value=$2

    case "${_vf_value}" in
        *[!A-Za-z0-9.-]*)
            fail "${_vf_name} contains invalid characters: ${_vf_value}"
            ;;
        .*|*.|*..*)
            fail "${_vf_name} must not start/end with a dot or contain consecutive dots: ${_vf_value}"
            ;;
    esac

    _vf_len=$(printf '%s' "${_vf_value}" | wc -c | tr -d ' ')
    [ "${_vf_len}" -le 253 ] || fail "${_vf_name} is too long: ${_vf_value}"

    _vf_remaining=${_vf_value}
    while :; do
        case "${_vf_remaining}" in
            *.*)
                _vf_label=${_vf_remaining%%.*}
                _vf_remaining=${_vf_remaining#*.}
                ;;
            *)
                _vf_label=${_vf_remaining}
                _vf_remaining=
                ;;
        esac

        [ -n "${_vf_label}" ] || fail "${_vf_name} contains an empty label: ${_vf_value}"

        _vf_label_len=$(printf '%s' "${_vf_label}" | wc -c | tr -d ' ')
        [ "${_vf_label_len}" -le 63 ] || fail "${_vf_name} label is too long: ${_vf_label}"

        case "${_vf_label}" in
            -*|*-)
                fail "${_vf_name} label must not start or end with a hyphen: ${_vf_label}"
                ;;
        esac

        [ -n "${_vf_remaining}" ] || break
    done
}
