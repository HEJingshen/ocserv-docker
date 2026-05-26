# syntax=docker/dockerfile:1.7

FROM debian:13-slim

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        fzf \
        gnutls-bin \
        openssl \
        util-linux; \
    rm -rf /var/lib/apt/lists/*

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
