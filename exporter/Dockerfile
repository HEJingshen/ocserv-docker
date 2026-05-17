# ==========================================
# ocserv Prometheus Exporter
# ==========================================
# 多阶段构建：从源码编译 occtl，确保与主服务版本一致
# ==========================================

# ==========================================
# 阶段一：编译环境 (Builder)
# ==========================================
# 与主 Dockerfile 保持一致的编译配置
FROM debian:trixie-slim AS builder

ARG OCSERV_VERSION=1.4.2

# 配置清华源加速
RUN [ -f /etc/apt/sources.list.d/debian.sources ] && \
    sed -i 's@//.*deb.debian.org@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list.d/debian.sources || true

# 安装编译依赖
RUN set -e; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential meson ninja-build pkg-config xz-utils \
    libgnutls28-dev libev-dev libreadline-dev libtasn1-bin \
    libpam0g-dev liblz4-dev libseccomp-dev \
    libnl-route-3-dev libkrb5-dev libradcli-dev \
    libcurl4-gnutls-dev libcjose-dev libjansson-dev liboath-dev \
    libprotobuf-c-dev libtalloc-dev libllhttp-dev protobuf-c-compiler \
    gawk iproute2 ipcalc ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 复制并编译 ocserv 源码
COPY src/ocserv-${OCSERV_VERSION}.tar.xz /tmp/ocserv-${OCSERV_VERSION}.tar.xz
RUN set -e; \
    cd /tmp && \
    tar -xf ocserv-${OCSERV_VERSION}.tar.xz && \
    cd ocserv-${OCSERV_VERSION} && \
    meson setup build --prefix /usr --buildtype=release && \
    ninja -C build && \
    DESTDIR=/out ninja -C build install && \
    rm -rf /tmp/ocserv-*

# ==========================================
# 阶段二：运行环境 (Runtime)
# ==========================================
# 使用与主 Dockerfile 相同的基础镜像，确保库兼容性
FROM debian:trixie-slim

ARG OCSERV_VERSION=1.4.2

LABEL maintainer="72605370+HEJingshen@users.noreply.github.com" \
      org.opencontainers.image.title="ocserv-exporter" \
      org.opencontainers.image.description="ocserv Prometheus Exporter" \
      org.opencontainers.image.version="${OCSERV_VERSION}"

# 配置清华源加速
RUN [ -f /etc/apt/sources.list.d/debian.sources ] && \
    sed -i 's@//.*deb.debian.org@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list.d/debian.sources || true

# 安装运行时依赖
# occtl 需要的库（比 ocserv 服务器少，无 iptables 等）
# iproute2 提供 ss 命令用于网络诊断
# libnl-route-3-200 是 occtl 必需的动态链接库
RUN set -e; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    libgnutls30t64 libev4 libreadline8t64 libtasn1-6 \
    libprotobuf-c1 libtalloc2 libllhttp9.2 libnl-route-3-200 \
    python3 python3-pip ca-certificates iproute2 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 从构建阶段复制 occtl 二进制文件
COPY --from=builder /out/usr/bin/occtl /usr/bin/occtl

# 安装 Python 依赖
RUN pip3 install --no-cache-dir prometheus-client --break-system-packages

# 创建工作目录
WORKDIR /app

# 复制 exporter 脚本
COPY exporter/ocserv-exporter.py .

# 环境变量默认值
ENV OCSERV_SOCKET=/var/run/occtl.socket
ENV METRICS_PORT=9100

# 暴露指标端口
EXPOSE 9100

# 运行 exporter
CMD ["python3", "ocserv-exporter.py"]