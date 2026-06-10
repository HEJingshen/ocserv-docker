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
