ARG BASE_IMAGE=debian:trixie-slim

FROM ${BASE_IMAGE} AS builder

ARG OCSERV_VERSION=1.4.2
ARG DEBIAN_FRONTEND=noninteractive
ARG USE_TUNA_MIRROR=true

RUN if [ "${USE_TUNA_MIRROR}" = "true" ] && [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's@//.*deb.debian.org@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
    fi

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        gawk \
        ipcalc \
        libev-dev \
        libgnutls28-dev \
        libkrb5-dev \
        liblz4-dev \
        libnl-route-3-dev \
        liboath-dev \
        libpam0g-dev \
        libprotobuf-c-dev \
        libradcli-dev \
        libreadline-dev \
        libseccomp-dev \
        libtalloc-dev \
        libtasn1-bin \
        meson \
        ninja-build \
        pkg-config \
        protobuf-c-compiler \
        xz-utils; \
    rm -rf /var/lib/apt/lists/*

COPY src/ocserv-${OCSERV_VERSION}.tar.xz /tmp/ocserv-${OCSERV_VERSION}.tar.xz

RUN set -eux; \
    cd /tmp; \
    tar -xf ocserv-${OCSERV_VERSION}.tar.xz; \
    cd ocserv-${OCSERV_VERSION}; \
    meson setup build \
        --prefix /usr \
        --buildtype=release \
        -Doidc-auth=disabled \
        -Dlocal-llhttp=true \
        -Dlocal-pcl=true; \
    ninja -C build; \
    DESTDIR=/out ninja -C build install; \
    rm -rf /tmp/ocserv-*

COPY src/s6-overlay-noarch.tar.xz /tmp/
COPY src/s6-overlay-x86_64.tar.xz /tmp/
COPY src/s6-overlay-aarch64.tar.xz /tmp/

RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
        amd64) S6_ARCH=x86_64 ;; \
        arm64) S6_ARCH=aarch64 ;; \
        *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
    esac; \
    mkdir -p /tmp/s6-out; \
    tar -Jxpf /tmp/s6-overlay-noarch.tar.xz -C /tmp/s6-out; \
    tar -Jxpf /tmp/s6-overlay-${S6_ARCH}.tar.xz -C /tmp/s6-out; \
    rm -f /tmp/s6-overlay-*.tar.xz

FROM ${BASE_IMAGE}

ARG OCSERV_VERSION=1.4.2
ARG S6_OVERLAY_VERSION=3.2.3.0
ARG BUILD_DATE
ARG DEBIAN_FRONTEND=noninteractive
ARG USE_TUNA_MIRROR=true

LABEL maintainer="72605370+HEJingshen@users.noreply.github.com" \
      org.opencontainers.image.title="ocserv" \
      org.opencontainers.image.description="OpenConnect VPN Server" \
      org.opencontainers.image.version="${OCSERV_VERSION}" \
      org.opencontainers.image.s6-overlay-version="${S6_OVERLAY_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/HEJingshen/ocserv-docker"

RUN if [ "${USE_TUNA_MIRROR}" = "true" ] && [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's@//.*deb.debian.org@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
    fi

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        iproute2 \
        iptables \
        libev4 \
        libgnutls30t64 \
        libkrb5-3 \
        liblz4-1 \
        libnl-route-3-200 \
        liboath0t64 \
        libpam0g \
        libprotobuf-c1 \
        libradcli4 \
        libreadline8t64 \
        libseccomp2 \
        libtalloc2 \
        libtasn1-6; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/ /
COPY --from=builder /tmp/s6-out/ /

ENV PATH="/command:${PATH}"

RUN set -eux; \
    mkdir -p /etc/ocserv /run/ocserv /var/log/ocserv \
             /etc/s6-overlay/s6-rc.d/ocserv-init \
             /etc/s6-overlay/s6-rc.d/ocserv \
             /etc/s6-overlay/s6-rc.d/ocserv/dependencies.d \
             /etc/s6-overlay/s6-rc.d/user/contents.d; \
    echo "oneshot" > /etc/s6-overlay/s6-rc.d/ocserv-init/type; \
    echo "longrun" > /etc/s6-overlay/s6-rc.d/ocserv/type; \
    ln -s ../ocserv-init /etc/s6-overlay/s6-rc.d/ocserv/dependencies.d/; \
    ln -s ../ocserv-init /etc/s6-overlay/s6-rc.d/user/contents.d/; \
    ln -s ../ocserv /etc/s6-overlay/s6-rc.d/user/contents.d/

RUN <<'ENDSCRIPT'
#!/bin/sh
set -e

cat > /etc/ocserv/s6-init.sh << 'INITFILE'
#!/bin/sh
set -e

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
                set -- ${VPN_NETMASK_VAL}
                IFS="${_old_IFS}"
                for _octet in "$1" "$2" "$3" "$4"; do
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
INITFILE
chmod +x /etc/ocserv/s6-init.sh

printf '#!/command/execlineb -P\n/etc/ocserv/s6-init.sh\n' \
    > /etc/s6-overlay/s6-rc.d/ocserv-init/up
chmod +x /etc/s6-overlay/s6-rc.d/ocserv-init/up

printf '#!/bin/sh\nexec ocserv -c /etc/ocserv/ocserv.conf -f\n' \
    > /etc/s6-overlay/s6-rc.d/ocserv/run
chmod +x /etc/s6-overlay/s6-rc.d/ocserv/run
ENDSCRIPT

EXPOSE 443/tcp 443/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ss -tln | grep -q ':443' || exit 1

ENTRYPOINT ["/init"]
