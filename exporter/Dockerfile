ARG BASE_IMAGE=debian:trixie-slim

FROM ${BASE_IMAGE} AS builder

ARG OCSERV_VERSION=1.4.2
ARG DEBIAN_FRONTEND=noninteractive

RUN if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's@//.*deb.debian.org@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
    fi

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        ipcalc \
        libev-dev \
        libgnutls28-dev \
        libnl-route-3-dev \
        libprotobuf-c-dev \
        libreadline-dev \
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
        -Dlocal-llhttp=true \
        -Dlocal-pcl=true; \
    ninja -C build src/occtl/occtl; \
    install -Dm755 build/src/occtl/occtl /out/usr/bin/occtl; \
    rm -rf /tmp/ocserv-*

FROM ${BASE_IMAGE}

ARG OCSERV_VERSION=1.4.2
ARG DEBIAN_FRONTEND=noninteractive

LABEL maintainer="72605370+HEJingshen@users.noreply.github.com" \
      org.opencontainers.image.title="ocserv-exporter" \
      org.opencontainers.image.description="ocserv Prometheus Exporter" \
      org.opencontainers.image.version="${OCSERV_VERSION}"

RUN if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's@//.*deb.debian.org@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
    fi

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libgnutls30t64 \
        libnl-route-3-200 \
        libprotobuf-c1 \
        libreadline8t64 \
        python3 \
        python3-prometheus-client; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/usr/bin/occtl /usr/bin/occtl

WORKDIR /app

COPY exporter/ocserv-exporter.py .

ENV OCSERV_SOCKET=/var/run/occtl.socket
ENV METRICS_PORT=9100
ENV EXPORTER_INTERVAL_SECONDS=15
ENV OCCTL_TIMEOUT_SECONDS=5

EXPOSE 9100

CMD ["python3", "ocserv-exporter.py"]
