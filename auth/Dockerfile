# syntax=docker/dockerfile:1.7

ARG ALPINE_IMAGE=alpine:3.23.4
ARG APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine

FROM ${ALPINE_IMAGE}

ARG APK_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine

COPY scripts/configure-alpine-repositories.sh /usr/local/bin/configure-alpine-repositories

RUN set -eux; \
    chmod +x /usr/local/bin/configure-alpine-repositories; \
    configure-alpine-repositories "${APK_MIRROR}"

RUN --mount=type=cache,target=/var/cache/apk \
    set -eux; \
    apk upgrade; \
    apk add --update-cache \
        bash \
        ca-certificates \
        coreutils \
        flock \
        fzf \
        gnutls-utils \
        openssl

COPY scripts/ocserv-cert-auth.sh /usr/local/bin/ocserv-cert-auth

RUN set -eux; \
    chmod +x /usr/local/bin/ocserv-cert-auth; \
    mkdir -p \
        /etc/ocserv/auth \
        /etc/ocserv/ca \
        /etc/ocserv/config-per-user \
        /var/lib/ocserv-auth/private-ca \
        /var/lib/ocserv-auth/user-certs

ENTRYPOINT ["/usr/local/bin/ocserv-cert-auth"]
