#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/common.sh"

DEFAULT_CHINA_IP_URL="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
DEFAULT_CHINA_IP_FILE="config/ip-lists/china.txt"
ENV_FILE="${PROJECT_ROOT}/.env"

env_or_file_value() {
    _eofv_name=$1
    _eofv_default=$2

    eval "_eofv_value=\${${_eofv_name}:-}"
    if [ -n "${_eofv_value}" ]; then
        printf '%s\n' "${_eofv_value}"
        return
    fi

    if [ -f "${ENV_FILE}" ]; then
        _eofv_value=$(env_file_value "${ENV_FILE}" "${_eofv_name}")
        if [ -n "${_eofv_value}" ]; then
            printf '%s\n' "${_eofv_value}"
            return
        fi
    fi

    printf '%s\n' "${_eofv_default}"
}

OCSERV_CHINA_IP_URL=$(env_or_file_value OCSERV_CHINA_IP_URL "${DEFAULT_CHINA_IP_URL}")
OCSERV_CHINA_IP_FILE=$(env_or_file_value OCSERV_CHINA_IP_FILE "${DEFAULT_CHINA_IP_FILE}")

case "${OCSERV_CHINA_IP_URL}" in
    https://*) ;;
    *) fail "OCSERV_CHINA_IP_URL must use HTTPS: ${OCSERV_CHINA_IP_URL}" ;;
esac

[ -n "${OCSERV_CHINA_IP_FILE}" ] || fail "OCSERV_CHINA_IP_FILE is empty"

case "${OCSERV_CHINA_IP_FILE}" in
    /*) output_file=${OCSERV_CHINA_IP_FILE} ;;
    *) output_file=${PROJECT_ROOT}/${OCSERV_CHINA_IP_FILE} ;;
esac

output_dir=$(dirname -- "${output_file}")
output_base=$(basename -- "${output_file}")
mkdir -p "${output_dir}"

tmp_prefix=${output_dir}/.${output_base}.$$
download_file=${tmp_prefix}.download
validated_file=${tmp_prefix}.validated

cleanup() {
    rm -f "${download_file}" "${validated_file}"
}
trap cleanup EXIT HUP INT TERM

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${OCSERV_CHINA_IP_URL}" -o "${download_file}"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "${download_file}" "${OCSERV_CHINA_IP_URL}"
else
    fail "curl or wget is required to download China IPv4 prefixes"
fi

prefix_count=$(
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }

        function valid_cidr(value, parts, octets, prefix, i, octet) {
            if (split(value, parts, "/") != 2) {
                return 0
            }
            if (parts[1] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                return 0
            }
            if (parts[2] !~ /^[0-9]+$/) {
                return 0
            }

            prefix = parts[2] + 0
            if (prefix < 1 || prefix > 32) {
                return 0
            }

            split(parts[1], octets, ".")
            for (i = 1; i <= 4; i++) {
                if (octets[i] !~ /^[0-9]+$/) {
                    return 0
                }
                octet = octets[i] + 0
                if (octet < 0 || octet > 255) {
                    return 0
                }
            }

            return 1
        }

        {
            line = trim($0)
            if (line == "" || line ~ /^#/) {
                next
            }

            if (!valid_cidr(line)) {
                printf "ERROR: invalid IPv4 CIDR: %s\n", line > "/dev/stderr"
                invalid = 1
                next
            }

            if (!(line in seen)) {
                seen[line] = 1
                ordered[++count] = line
            }
        }

        END {
            if (invalid) {
                exit 1
            }
            for (i = 1; i <= count; i++) {
                print ordered[i] > out
            }
            print count
        }
    ' out="${validated_file}" "${download_file}"
)

if [ "${prefix_count}" -lt 1000 ] || [ "${prefix_count}" -gt 20000 ]; then
    fail "unexpected China IPv4 prefix count: ${prefix_count}"
fi

chmod 0644 "${validated_file}"
mv "${validated_file}" "${output_file}"

printf 'Saved %s validated China IPv4 prefixes to %s\n' "${prefix_count}" "${output_file}"
