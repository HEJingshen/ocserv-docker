FROM ubuntu:24.04

LABEL maintainer="your-email@example.com"

RUN apt-get update && \
    apt-get install -y \
    ocserv \
    iptables \
    gnutls-bin \
    wget \
    sudo \
    net-tools \
    nano \
    && apt-get clean

RUN mkdir -p /etc/ocserv

EXPOSE 443/tcp
EXPOSE 443/udp

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

CMD ["ocserv", "-c", "/etc/ocserv/ocserv.conf", "-f"]
