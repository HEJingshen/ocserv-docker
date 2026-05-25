# syntax=docker/dockerfile:1.7

ARG ALPINE_IMAGE=alpine:3.23.4

FROM ${ALPINE_IMAGE} AS builder

ARG OCSERV_VERSION=1.4.2
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
        gnutls-dev \
        libev-dev \
        libnl3-dev \
        linux-headers \
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
    fi

COPY src/ocserv-${OCSERV_VERSION}.tar.xz /tmp/ocserv-${OCSERV_VERSION}.tar.xz

RUN set -eux; \
    cd /tmp; \
    tar -xf ocserv-${OCSERV_VERSION}.tar.xz; \
    cd ocserv-${OCSERV_VERSION}; \
    meson setup build \
        --prefix /usr \
        --buildtype=release \
        -Dpam=disabled \
        -Dradius=disabled \
        -Dgssapi=disabled \
        -Dliboath=disabled \
        -Dlz4=disabled \
        -Dseccomp=disabled \
        -Dsystemd=disabled \
        -Doidc-auth=disabled \
        -Dutmp=disabled \
        -Dlibwrap=disabled \
        -Dlibnl=enabled \
        -Dlocal-llhttp=true \
        -Dlocal-pcl=true; \
    ninja -C build src/occtl/occtl; \
    install -Dm755 build/src/occtl/occtl /out/usr/bin/occtl; \
    rm -rf /tmp/ocserv-*

FROM ${ALPINE_IMAGE}

ARG OCSERV_VERSION=1.4.2
ARG ALPINE_IMAGE=alpine:3.23.4
ARG ALPINE_VERSION=3.23.4
ARG BUILD_DATE
ARG APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine

LABEL maintainer="72605370+GentleKingson@users.noreply.github.com" \
      org.opencontainers.image.title="ocserv-exporter-alpine" \
      org.opencontainers.image.description="ocserv Prometheus Exporter Alpine image" \
      org.opencontainers.image.version="${OCSERV_VERSION}" \
      org.opencontainers.image.alpine-version="${ALPINE_VERSION}" \
      org.opencontainers.image.base.name="${ALPINE_IMAGE}" \
      org.opencontainers.image.created="${BUILD_DATE}"

COPY scripts/configure-alpine-repositories.sh /usr/local/bin/configure-alpine-repositories

RUN set -eux; \
    chmod +x /usr/local/bin/configure-alpine-repositories; \
    configure-alpine-repositories "${APK_MIRROR}"

COPY --from=builder /out/usr/bin/occtl /usr/bin/occtl

RUN --mount=type=cache,target=/var/cache/apk \
    set -eux; \
    apk add --update-cache \
        ca-certificates \
        pax-utils \
        py3-prometheus-client \
        python3; \
    runDeps="$(scanelf --needed --nobanner --format '%n#p' /usr/bin/occtl \
        | tr ',' '\n' \
        | sort -u \
        | awk 'NF { print "so:" $1 }')"; \
    apk add --update-cache --virtual .occtl-rundeps ${runDeps}

WORKDIR /app

COPY --chown=nobody:nobody exporter/ocserv_exporter.py .

ENV OCSERV_SOCKET=/var/run/occtl.socket
ENV METRICS_PORT=9100
ENV EXPORTER_INTERVAL_SECONDS=10
ENV OCCTL_TIMEOUT_SECONDS=5
ENV EXPORTER_ENABLE_SESSION_DETAIL_METRICS=false

EXPOSE 9100

USER nobody

CMD ["python3", "-m", "ocserv_exporter"]
