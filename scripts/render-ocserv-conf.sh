#!/bin/sh
set -eu

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=scripts/common.sh disable=SC1091
. "${SCRIPT_DIR}/common.sh"

ENV_FILE=${ENV_FILE:-"${PROJECT_ROOT}/.env"}
TEMPLATE_FILE=${OCSERV_CONF_TEMPLATE:-"${PROJECT_ROOT}/config/ocserv.conf.template"}
CHINA_ROUTE_MARKER='# @OCSERV_CHINA_IPV4_ROUTES@'

[ -f "${ENV_FILE}" ] || fail "env file not found: ${ENV_FILE}. Copy .env.example to .env first."
[ -f "${TEMPLATE_FILE}" ] || fail "template file not found: ${TEMPLATE_FILE}"

OCSERV_CONF_DIR=${OCSERV_CONF_DIR:-$(env_file_value "${ENV_FILE}" OCSERV_CONF_DIR)}
OCSERV_CONF_DIR="${OCSERV_CONF_DIR:-/etc/ocserv}"
OUTPUT_FILE=${OCSERV_CONF_OUTPUT:-"${OCSERV_CONF_DIR}/ocserv.conf"}

DOMAIN=${DOMAIN:-$(env_file_value "${ENV_FILE}" DOMAIN)}
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-$(env_file_value "${ENV_FILE}" OCSERV_ENABLE_COMPRESSION)}
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-false}  # default: keep in sync with .env.example
OCSERV_NO_UDP=${OCSERV_NO_UDP:-$(env_file_value "${ENV_FILE}" OCSERV_NO_UDP)}
OCSERV_NO_UDP=${OCSERV_NO_UDP:-false}  # default: keep in sync with .env.example
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-$(env_file_value "${ENV_FILE}" OCSERV_MAX_CLIENTS)}
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-32}  # default: keep in sync with .env.example
OCSERV_CHINA_ROUTES_ENABLED=${OCSERV_CHINA_ROUTES_ENABLED:-$(env_file_value "${ENV_FILE}" OCSERV_CHINA_ROUTES_ENABLED)}
OCSERV_CHINA_ROUTES_ENABLED=${OCSERV_CHINA_ROUTES_ENABLED:-false}
OCSERV_CHINA_ROUTES_MODE=${OCSERV_CHINA_ROUTES_MODE:-$(env_file_value "${ENV_FILE}" OCSERV_CHINA_ROUTES_MODE)}
OCSERV_CHINA_ROUTES_MODE=${OCSERV_CHINA_ROUTES_MODE:-route}
OCSERV_CHINA_IP_FILE=${OCSERV_CHINA_IP_FILE:-$(env_file_value "${ENV_FILE}" OCSERV_CHINA_IP_FILE)}
OCSERV_CHINA_IP_FILE=${OCSERV_CHINA_IP_FILE:-config/ip-lists/china.txt}

validate_domain DOMAIN "${DOMAIN}"

validate_bool OCSERV_ENABLE_COMPRESSION "${OCSERV_ENABLE_COMPRESSION}"
validate_bool OCSERV_NO_UDP "${OCSERV_NO_UDP}"
validate_bool OCSERV_CHINA_ROUTES_ENABLED "${OCSERV_CHINA_ROUTES_ENABLED}"

case "${OCSERV_CHINA_ROUTES_MODE}" in
    route|no-route)
        ;;
    *)
        fail "OCSERV_CHINA_ROUTES_MODE must be route or no-route: ${OCSERV_CHINA_ROUTES_MODE}"
        ;;
esac

case "${OCSERV_MAX_CLIENTS}" in
    ''|*[!0-9]*)
        fail "OCSERV_MAX_CLIENTS must be a positive integer: ${OCSERV_MAX_CLIENTS}"
        ;;
esac
[ "${OCSERV_MAX_CLIENTS}" -ge 1 ] || fail "OCSERV_MAX_CLIENTS must be at least 1"

# Validate TLS certificate paths
TLS_CERT_FILE=${TLS_CERT_FILE:-$(env_file_value "${ENV_FILE}" TLS_CERT_FILE)}
TLS_KEY_FILE=${TLS_KEY_FILE:-$(env_file_value "${ENV_FILE}" TLS_KEY_FILE)}
validate_tls_paths "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"

MARKER_COUNT=$(grep -Fxc "${CHINA_ROUTE_MARKER}" "${TEMPLATE_FILE}" || true)
[ "${MARKER_COUNT}" -eq 1 ] \
    || fail "template must contain exactly one marker line: ${CHINA_ROUTE_MARKER}"

OUTPUT_DIR=$(dirname -- "${OUTPUT_FILE}")
mkdir -p "${OUTPUT_DIR}" 2>/dev/null || fail "cannot create output directory: ${OUTPUT_DIR} (run with sudo)"

TMP_FILE=
CHINA_ROUTE_FILE=

cleanup() {
    [ -z "${TMP_FILE:-}" ] || rm -f "${TMP_FILE}"
    [ -z "${CHINA_ROUTE_FILE:-}" ] || rm -f "${CHINA_ROUTE_FILE}"
}

trap cleanup EXIT HUP INT TERM

TMP_FILE=$(mktemp "${OUTPUT_DIR}/.ocserv.conf.XXXXXX") || fail "failed to create temporary config"
CHINA_ROUTE_FILE=$(mktemp "${OUTPUT_DIR}/.ocserv-china-routes.XXXXXX") || fail "failed to create route temporary file"

CHINA_ROUTE_COUNT=0

if [ "${OCSERV_CHINA_ROUTES_ENABLED}" = true ]; then
    case "${OCSERV_CHINA_IP_FILE}" in
        /*)
            ;;
        *)
            OCSERV_CHINA_IP_FILE="${PROJECT_ROOT}/${OCSERV_CHINA_IP_FILE}"
            ;;
    esac

    validate_regular_file OCSERV_CHINA_IP_FILE "${OCSERV_CHINA_IP_FILE}"

    if ! awk -v mode="${OCSERV_CHINA_ROUTES_MODE}" '
        function mask_octet(bits) {
            if (bits >= 8) return 255
            if (bits <= 0) return 0
            if (bits == 1) return 128
            if (bits == 2) return 192
            if (bits == 3) return 224
            if (bits == 4) return 240
            if (bits == 5) return 248
            if (bits == 6) return 252
            if (bits == 7) return 254
        }

        function prefix_to_mask(prefix, remaining, a, b, c, d) {
            remaining = prefix

            a = mask_octet(remaining)
            remaining -= 8

            b = mask_octet(remaining)
            remaining -= 8

            c = mask_octet(remaining)
            remaining -= 8

            d = mask_octet(remaining)

            return a "." b "." c "." d
        }

        function valid_cidr(value, parts, octets, count, i, prefix) {
            count = split(value, parts, "/")

            if (count != 2 || parts[2] !~ /^[0-9]+$/) {
                return 0
            }

            prefix = parts[2] + 0

            if (prefix < 1 || prefix > 32) {
                return 0
            }

            count = split(parts[1], octets, ".")

            if (count != 4) {
                return 0
            }

            for (i = 1; i <= 4; i++) {
                if (octets[i] !~ /^[0-9]+$/) {
                    return 0
                }

                if (octets[i] + 0 < 0 || octets[i] + 0 > 255) {
                    return 0
                }
            }

            return 1
        }

        BEGIN {
            print "# BEGIN generated China IPv4 routes; do not edit this block"
            print "# Mode: " mode

            if (mode == "no-route") {
                print "route = default"
            }
        }

        {
            line = $0

            sub(/\r$/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)

            if (line == "" || substr(line, 1, 1) == "#") {
                next
            }

            if (!valid_cidr(line)) {
                printf "invalid IPv4 CIDR at list line %d: %s\n", NR, line > "/dev/stderr"
                invalid = 1
                next
            }

            if (seen[line]++) {
                next
            }

            split(line, cidr_parts, "/")
            converted = cidr_parts[1] "/" prefix_to_mask(cidr_parts[2] + 0)

            if (mode == "route") {
                print "route = " converted
            } else {
                print "no-route = " converted
            }

            count++
        }

        END {
            if (invalid) {
                exit 2
            }

            if (count < 1000 || count > 20000) {
                printf "unexpected China IPv4 prefix count: %d\n", count > "/dev/stderr"
                exit 3
            }

            print "# END generated China IPv4 routes; prefixes=" count
        }
    ' "${OCSERV_CHINA_IP_FILE}" > "${CHINA_ROUTE_FILE}"; then
        fail "China IPv4 list validation or conversion failed: ${OCSERV_CHINA_IP_FILE}"
    fi

    case "${OCSERV_CHINA_ROUTES_MODE}" in
        route)
            CHINA_ROUTE_COUNT=$(grep -c '^route = ' "${CHINA_ROUTE_FILE}" || true)
            ;;
        no-route)
            CHINA_ROUTE_COUNT=$(grep -c '^no-route = ' "${CHINA_ROUTE_FILE}" || true)
            ;;
    esac
else
    {
        printf '%s\n' '# BEGIN generated China IPv4 routes'
        printf '%s\n' '# Disabled by OCSERV_CHINA_ROUTES_ENABLED=false'
        printf '%s\n' '# END generated China IPv4 routes'
    } > "${CHINA_ROUTE_FILE}"
fi

awk \
    -v domain="${DOMAIN}" \
    -v enable_compression="${OCSERV_ENABLE_COMPRESSION}" \
    -v no_udp="${OCSERV_NO_UDP}" \
    -v max_clients="${OCSERV_MAX_CLIENTS}" \
    -v china_route_marker="${CHINA_ROUTE_MARKER}" \
    -v china_route_file="${CHINA_ROUTE_FILE}" '
    $0 == china_route_marker {
        while ((getline route_line < china_route_file) > 0) {
            print route_line
        }

        close(china_route_file)
        next
    }

    {
        gsub(/\$\{DOMAIN\}/, domain)
        if ($0 ~ /^[[:space:]]*compression[[:space:]]*=/) {
            print "compression = " enable_compression
            next
        }
        if ($0 ~ /^[[:space:]]*no-udp[[:space:]]*=/) {
            print "no-udp = " no_udp
            next
        }
        if ($0 ~ /^[[:space:]]*max-clients[[:space:]]*=/) {
            sub(/=.*/, "= " max_clients)
        }
        print
    }
' "${TEMPLATE_FILE}" > "${TMP_FILE}"

# shellcheck disable=SC2016
if grep -q '\${DOMAIN}' "${TMP_FILE}"; then
    fail "unrendered DOMAIN placeholder remains in generated config"
fi

if grep -Fq "${CHINA_ROUTE_MARKER}" "${TMP_FILE}"; then
    fail "unrendered China route marker remains in generated config"
fi

chmod 0644 "${TMP_FILE}"

mv "${TMP_FILE}" "${OUTPUT_FILE}"
TMP_FILE=

printf 'Rendered %s from %s using DOMAIN=%s OCSERV_MAX_CLIENTS=%s OCSERV_ENABLE_COMPRESSION=%s OCSERV_NO_UDP=%s OCSERV_CHINA_ROUTES_ENABLED=%s OCSERV_CHINA_ROUTES_MODE=%s CHINA_PREFIXES=%s\n' \
    "${OUTPUT_FILE}" \
    "${TEMPLATE_FILE}" \
    "${DOMAIN}" \
    "${OCSERV_MAX_CLIENTS}" \
    "${OCSERV_ENABLE_COMPRESSION}" \
    "${OCSERV_NO_UDP}" \
    "${OCSERV_CHINA_ROUTES_ENABLED}" \
    "${OCSERV_CHINA_ROUTES_MODE}" \
    "${CHINA_ROUTE_COUNT}"
