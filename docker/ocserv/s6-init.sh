#!/bin/sh
set -eu

echo "=== ocserv initialization start ==="

if [ ! -f /etc/ocserv/ocserv.conf ]; then
    echo "ERROR: /etc/ocserv/ocserv.conf not found"
    echo "  Mount config via -v ./config/ocserv.conf:/etc/ocserv/ocserv.conf:ro"
    exit 1
fi

if [ ! -r /etc/ocserv/ocserv.conf ]; then
    echo "ERROR: /etc/ocserv/ocserv.conf is not readable"
    exit 1
fi

if ! command -v ocserv >/dev/null 2>&1; then
    echo "ERROR: ocserv binary not found"
    exit 1
fi

mkdir -p /run/ocserv /var/log/ocserv

VPN_CIDR=""
VPN_NETWORK_VAL=$(grep -E '^[[:space:]]*ipv4-network[[:space:]]*=' /etc/ocserv/ocserv.conf 2>/dev/null \
    | head -1 | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*[#;].*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')

if [ -n "${VPN_NETWORK_VAL}" ]; then
    case "${VPN_NETWORK_VAL}" in
        */*)
            VPN_CIDR="${VPN_NETWORK_VAL}"
            ;;
        *)
            VPN_NETMASK_VAL=$(grep -E '^[[:space:]]*ipv4-netmask[[:space:]]*=' /etc/ocserv/ocserv.conf 2>/dev/null \
                | head -1 | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*[#;].*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "${VPN_NETMASK_VAL}" ]; then
                _prefix=0
                _old_IFS="${IFS}"
                IFS='.'
                # shellcheck disable=SC2086
                set -- ${VPN_NETMASK_VAL}
                IFS="${_old_IFS}"
                if [ "$#" -ne 4 ]; then
                    _prefix=0
                fi
                for _octet in "${1:-}" "${2:-}" "${3:-}" "${4:-}"; do
                    case "${_octet}" in
                        255) _prefix=$((_prefix + 8)) ;;
                        254) _prefix=$((_prefix + 7)) ;;
                        252) _prefix=$((_prefix + 6)) ;;
                        248) _prefix=$((_prefix + 5)) ;;
                        240) _prefix=$((_prefix + 4)) ;;
                        224) _prefix=$((_prefix + 3)) ;;
                        192) _prefix=$((_prefix + 2)) ;;
                        128) _prefix=$((_prefix + 1)) ;;
                        0) ;;
                        *) _prefix=0; break ;;
                    esac
                done
                if [ "${_prefix}" -gt 0 ]; then
                    VPN_CIDR="${VPN_NETWORK_VAL}/${_prefix}"
                fi
            fi
            ;;
    esac
fi

if [ -z "${VPN_CIDR}" ]; then
    VPN_CIDR="10.10.10.0/24"
    echo "WARNING: Unable to parse VPN subnet from config, using default ${VPN_CIDR}"
fi

echo "Configuring iptables for VPN subnet: ${VPN_CIDR}"

DEFAULT_IF=$(ip route | awk '/default/ {print $5; exit}')
if [ -z "${DEFAULT_IF}" ]; then
    DEFAULT_IF="eth0"
fi

echo "Default outbound interface: ${DEFAULT_IF}"

iptables -C FORWARD -s "${VPN_CIDR}" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -s "${VPN_CIDR}" -j ACCEPT
iptables -C FORWARD -d "${VPN_CIDR}" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -d "${VPN_CIDR}" -j ACCEPT
iptables -t nat -C POSTROUTING -s "${VPN_CIDR}" -o "${DEFAULT_IF}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "${VPN_CIDR}" -o "${DEFAULT_IF}" -j MASQUERADE

echo "iptables rules configured successfully"
echo "=== ocserv initialization complete ==="
exit 0
