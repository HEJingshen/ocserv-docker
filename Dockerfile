ARG ALPINE_VERSION=3.23
ARG ALPINE_PATCH_VERSION=3.23.4
ARG ALPINE_ARCH=x86_64

FROM scratch AS alpine-rootfs
ARG ALPINE_VERSION
ARG ALPINE_PATCH_VERSION
ARG ALPINE_ARCH
ADD src/alpine-minirootfs-${ALPINE_PATCH_VERSION}-${ALPINE_ARCH}.tar.gz /
CMD ["/bin/sh"]

FROM alpine-rootfs AS builder

ARG OCSERV_VERSION=1.4.2
ARG ALPINE_FLAVOR=slim
ARG APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine

RUN set -eux; \
    . /etc/os-release; \
    ALPINE_BRANCH="${VERSION_ID}"; \
    case "${ALPINE_BRANCH}" in \
        *.*.*) ALPINE_BRANCH="${ALPINE_BRANCH%.*}" ;; \
    esac; \
    printf '%s/v%s/main\n%s/v%s/community\n' \
        "${APK_MIRROR}" "${ALPINE_BRANCH}" \
        "${APK_MIRROR}" "${ALPINE_BRANCH}" \
        > /etc/apk/repositories

RUN set -eux; \
    apk add --no-cache \
        build-base \
        ca-certificates \
        gawk \
        gnutls-dev \
        gperf \
        libev-dev \
        libnl3-dev \
        linux-headers \
        lz4-dev \
        meson \
        nettle-dev \
        ninja \
        pkgconf \
        protobuf-c-dev \
        protobuf-c-compiler \
        readline-dev \
        xz; \
    if ! command -v ipcalc >/dev/null 2>&1; then \
        printf '#!/bin/sh\nexec busybox ipcalc "$@"\n' > /usr/local/bin/ipcalc; \
        chmod +x /usr/local/bin/ipcalc; \
    fi; \
    case "${ALPINE_FLAVOR}" in \
        slim) \
            apk add --no-cache libxcrypt-dev || true; \
            ;; \
        full) \
            apk add --no-cache \
                krb5-dev \
                libseccomp-dev \
                libtasn1-dev \
                linux-pam-dev \
                talloc-dev; \
            apk add --no-cache oath-toolkit-dev || echo "WARNING: oath-toolkit-dev unavailable; OTP/liboath will remain auto-detected"; \
            apk add --no-cache radcli-dev || echo "WARNING: radcli-dev unavailable; RADIUS will remain auto-detected"; \
            apk add --no-cache libxcrypt-dev || true; \
            ;; \
        *) \
            echo "Unsupported ALPINE_FLAVOR=${ALPINE_FLAVOR}; expected slim or full"; \
            exit 1; \
            ;; \
    esac

COPY src/ocserv-${OCSERV_VERSION}.tar.xz /tmp/ocserv-${OCSERV_VERSION}.tar.xz

RUN set -eux; \
    cd /tmp; \
    tar -xf ocserv-${OCSERV_VERSION}.tar.xz; \
    cd ocserv-${OCSERV_VERSION}; \
    case "${ALPINE_FLAVOR}" in \
        slim) \
            MESON_FEATURES="-Dpam=disabled -Dradius=disabled -Dgssapi=disabled -Dliboath=disabled -Dsystemd=disabled -Dutmp=disabled -Dlibwrap=disabled -Dseccomp=disabled -Dlz4=enabled -Dlibnl=enabled"; \
            ;; \
        full) \
            MESON_FEATURES="-Dpam=enabled -Dradius=auto -Dgssapi=enabled -Dliboath=auto -Dsystemd=disabled -Dutmp=auto -Dlibwrap=auto -Dseccomp=enabled -Dlz4=enabled -Dlibnl=enabled"; \
            ;; \
    esac; \
    meson setup build \
        --prefix /usr \
        --buildtype=release \
        -Doidc-auth=disabled \
        -Dfirewall-script=iptables \
        -Dlocal-llhttp=true \
        -Dlocal-pcl=true \
        ${MESON_FEATURES}; \
    ninja -C build; \
    DESTDIR=/out ninja -C build install; \
    rm -rf /tmp/ocserv-*

FROM alpine-rootfs

ARG OCSERV_VERSION=1.4.2
ARG S6_OVERLAY_VERSION=3.2.3.0
ARG ALPINE_VERSION=3.23
ARG ALPINE_PATCH_VERSION=3.23.4
ARG ALPINE_ARCH=x86_64
ARG ALPINE_MINIROOTFS_SHA256
ARG ALPINE_FLAVOR=slim
ARG S6_SOURCE=auto
ARG BUILD_DATE
ARG APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine
ARG TARGETARCH

LABEL maintainer="72605370+HEJingshen@users.noreply.github.com" \
      org.opencontainers.image.title="ocserv-alpine-minirootfs" \
      org.opencontainers.image.description="OpenConnect VPN Server Alpine minirootfs feasibility image" \
      org.opencontainers.image.version="${OCSERV_VERSION}" \
      org.opencontainers.image.alpine-version="${ALPINE_VERSION}" \
      org.opencontainers.image.alpine-minirootfs-version="${ALPINE_PATCH_VERSION}" \
      org.opencontainers.image.alpine-minirootfs-arch="${ALPINE_ARCH}" \
      org.opencontainers.image.alpine-minirootfs-sha256="${ALPINE_MINIROOTFS_SHA256}" \
      org.opencontainers.image.s6-overlay-version="${S6_OVERLAY_VERSION}" \
      org.opencontainers.image.alpine-flavor="${ALPINE_FLAVOR}" \
      org.opencontainers.image.s6-source="${S6_SOURCE}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/HEJingshen/ocserv-docker"

RUN set -eux; \
    . /etc/os-release; \
    ALPINE_BRANCH="${VERSION_ID}"; \
    case "${ALPINE_BRANCH}" in \
        *.*.*) ALPINE_BRANCH="${ALPINE_BRANCH%.*}" ;; \
    esac; \
    printf '%s/v%s/main\n%s/v%s/community\n' \
        "${APK_MIRROR}" "${ALPINE_BRANCH}" \
        "${APK_MIRROR}" "${ALPINE_BRANCH}" \
        > /etc/apk/repositories

COPY --from=builder /out/ /
COPY src/s6-overlay-noarch.tar.xz /tmp/
COPY src/s6-overlay-x86_64.tar.xz /tmp/
COPY src/s6-overlay-aarch64.tar.xz /tmp/

RUN set -eux; \
    apk add --no-cache \
        ca-certificates \
        grep \
        iproute2 \
        iptables \
        pax-utils \
        sed \
        tzdata \
        xz; \
    runDeps="$(scanelf --needed --nobanner --format '%n#p' \
            /usr/bin/occtl /usr/bin/ocpasswd /usr/sbin/ocserv /usr/sbin/ocserv-worker \
        | tr ',' '\n' \
        | sort -u \
        | awk 'NF { print "so:" $1 }')"; \
    apk add --no-cache --virtual .ocserv-rundeps ${runDeps}; \
    case "${S6_SOURCE}" in \
        apk) \
            apk add --no-cache s6-overlay; \
            [ -x /init ]; \
            ;; \
        tarball) \
            /bin/sh -c 'case "${TARGETARCH}" in amd64) S6_ARCH=x86_64 ;; arm64) S6_ARCH=aarch64 ;; *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1 ;; esac; tar -Jxpf /tmp/s6-overlay-noarch.tar.xz -C /; tar -Jxpf /tmp/s6-overlay-${S6_ARCH}.tar.xz -C /'; \
            ;; \
        auto) \
            if apk add --no-cache s6-overlay && [ -x /init ]; then \
                echo "Using Alpine s6-overlay package"; \
            else \
                echo "Falling back to bundled s6-overlay tarballs"; \
                case "${TARGETARCH}" in \
                    amd64) S6_ARCH=x86_64 ;; \
                    arm64) S6_ARCH=aarch64 ;; \
                    *) echo "Unsupported TARGETARCH=${TARGETARCH}"; exit 1 ;; \
                esac; \
                tar -Jxpf /tmp/s6-overlay-noarch.tar.xz -C /; \
                tar -Jxpf /tmp/s6-overlay-${S6_ARCH}.tar.xz -C /; \
            fi; \
            ;; \
        *) \
            echo "Unsupported S6_SOURCE=${S6_SOURCE}; expected auto, apk, or tarball"; \
            exit 1; \
            ;; \
    esac; \
    rm -f /tmp/s6-overlay-*.tar.xz

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
