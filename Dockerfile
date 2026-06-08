# syntax=docker/dockerfile:1.7
#
# Dockerfile for ocserv (standard build without SAML support)
# For SAML 2.0 authentication support, use Dockerfile.saml
#

ARG ALPINE_IMAGE=alpine:3.23.4

# Stage 1: Build ocserv
FROM ${ALPINE_IMAGE} AS builder

ARG OCSERV_VERSION
ARG APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine

COPY scripts/configure-alpine-repositories.sh /usr/local/bin/configure-alpine-repositories

RUN set -eux; \
    chmod +x /usr/local/bin/configure-alpine-repositories; \
    configure-alpine-repositories "${APK_MIRROR}"

RUN --mount=type=cache,target=/var/cache/apk \
    set -eux; \
    apk add --update-cache \
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
    apk add --update-cache \
        krb5-dev \
        libtasn1-dev \
        linux-pam-dev \
        talloc-dev; \
    apk add --update-cache oath-toolkit-dev || echo "WARNING: oath-toolkit-dev unavailable; OTP/liboath will remain auto-detected"; \
    apk add --update-cache radcli-dev || echo "WARNING: radcli-dev unavailable; RADIUS will remain auto-detected"; \
    apk add --update-cache libxcrypt-dev || true

COPY src/ocserv-${OCSERV_VERSION}.tar.xz /tmp/ocserv.tar.xz

RUN set -eux; \
    cd /tmp && tar -xf ocserv.tar.xz && cd ocserv-${OCSERV_VERSION}; \
    meson setup build \
        --prefix /usr \
        --buildtype release \
        -Doidc-auth=disabled \
        -Dfirewall-script=iptables \
        -Dlocal-llhttp=true \
        -Dlocal-pcl=true \
        -Dpam=enabled \
        -Dradius=auto \
        -Dgssapi=enabled \
        -Dliboath=auto \
        -Dsystemd=disabled \
        -Dutmp=auto \
        -Dlibwrap=auto \
        -Dseccomp=disabled \
        -Dlz4=enabled \
        -Dlibnl=enabled; \
    ninja -C build; \
    DESTDIR=/out ninja -C build install; \
    rm -rf /tmp/ocserv-*

# Stage 2: Runtime image
FROM ${ALPINE_IMAGE}

ARG OCSERV_VERSION
ARG ALPINE_IMAGE=alpine:3.23.4
ARG ALPINE_VERSION=3.23.4
ARG BUILD_DATE
ARG APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine

LABEL maintainer="72605370+GentleKingson@users.noreply.github.com" \
      org.opencontainers.image.title="ocserv-alpine" \
      org.opencontainers.image.description="OpenConnect VPN Server Alpine image" \
      org.opencontainers.image.version="${OCSERV_VERSION}" \
      org.opencontainers.image.alpine-version="${ALPINE_VERSION}" \
      org.opencontainers.image.base.name="${ALPINE_IMAGE}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/GentleKingson/ocserv-docker"

COPY scripts/configure-alpine-repositories.sh /usr/local/bin/configure-alpine-repositories

RUN set -eux; \
    chmod +x /usr/local/bin/configure-alpine-repositories; \
    configure-alpine-repositories "${APK_MIRROR}"

COPY --from=builder /out/ /

RUN --mount=type=cache,target=/var/cache/apk \
    set -eux; \
    apk add --update-cache \
        ca-certificates \
        grep \
        iproute2 \
        iptables \
        pax-utils \
        sed \
        tzdata; \
    runDeps="$(scanelf --needed --nobanner --format '%n#p' \
            /usr/bin/occtl /usr/bin/ocpasswd /usr/sbin/ocserv /usr/sbin/ocserv-worker \
        | tr ',' '\n' \
        | sort -u \
        | awk 'NF { print "so:" $1 }' \
        | grep -v 'liblasso' || true)"; \
    apk add --update-cache --virtual .ocserv-rundeps ${runDeps}; \
    apk add --update-cache s6-overlay; \
    [ -x /init ]

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

COPY docker/ocserv/s6-init.sh /etc/ocserv/s6-init.sh

RUN set -eux; \
    chmod +x /etc/ocserv/s6-init.sh; \
    printf '#!/command/execlineb -P\n/etc/ocserv/s6-init.sh\n' \
        > /etc/s6-overlay/s6-rc.d/ocserv-init/up; \
    chmod +x /etc/s6-overlay/s6-rc.d/ocserv-init/up; \
    printf '#!/bin/sh\nexec ocserv -c /etc/ocserv/ocserv.conf -f\n' \
        > /etc/s6-overlay/s6-rc.d/ocserv/run; \
    chmod +x /etc/s6-overlay/s6-rc.d/ocserv/run

EXPOSE 443/tcp 443/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ss -tln | grep -q ':443' || exit 1

ENTRYPOINT ["/init"]