# ==========================================
# ocserv VPN Server Docker Image
# ==========================================
# 注意：本文件使用 POSIX sh 语法（Docker 默认 /bin/sh = dash）
# 请勿使用 bash 特性（如 [[ ]]、数组、函数等）
#
# 约定：所有 FROM 后的第一条 RUN 都配置清华源
# ==========================================

# Base image（可通过 --build-arg BASE_IMAGE=... 自定义）
ARG BASE_IMAGE=debian:trixie-slim

# ==========================================
# 阶段一：编译环境 (Builder)
# ==========================================
FROM ${BASE_IMAGE} AS builder

ARG OCSERV_VERSION=1.4.2
ARG BUILD_DATE

# 配置清华源加速（文件不存在时跳过，避免 set -e 终止构建）
RUN [ -f /etc/apt/sources.list.d/debian.sources ] && \
    sed -i 's@//.*deb.debian.org@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list.d/debian.sources || true

# 安装编译依赖（仅编译所需，测试套件依赖已移除）
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

# 复制本地 ocserv 源码并编译
COPY src/ocserv-${OCSERV_VERSION}.tar.xz /tmp/ocserv-${OCSERV_VERSION}.tar.xz
RUN set -e; \
    cd /tmp && \
    tar -xf ocserv-${OCSERV_VERSION}.tar.xz && \
    cd ocserv-${OCSERV_VERSION} && \
    meson setup build --prefix /usr --buildtype=release && \
    ninja -C build && \
    DESTDIR=/out ninja -C build install && \
    rm -rf /tmp/ocserv-*

# 在 builder 阶段解压 s6-overlay（此阶段有 xz-utils）
COPY src/s6-overlay-noarch.tar.xz /tmp/
COPY src/s6-overlay-x86_64.tar.xz /tmp/
COPY src/s6-overlay-aarch64.tar.xz /tmp/
RUN set -e; \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
        amd64) S6_ARCH=x86_64 ;; \
        arm64) S6_ARCH=aarch64 ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    echo "Extracting s6-overlay for ${S6_ARCH} in builder..." && \
    mkdir -p /tmp/s6-out && \
    tar -Jxpf /tmp/s6-overlay-noarch.tar.xz -C /tmp/s6-out && \
    tar -Jxpf /tmp/s6-overlay-${S6_ARCH}.tar.xz -C /tmp/s6-out && \
    rm -f /tmp/s6-overlay-*.tar.xz

# ==========================================
# 阶段二：运行环境 (Runtime)
# ==========================================
FROM ${BASE_IMAGE}

ARG OCSERV_VERSION=1.4.2
ARG S6_OVERLAY_VERSION=3.2.3.0
ARG BUILD_DATE

LABEL maintainer="72605370+HEJingshen@users.noreply.github.com" \
      org.opencontainers.image.title="ocserv" \
      org.opencontainers.image.description="OpenConnect VPN Server" \
      org.opencontainers.image.version="${OCSERV_VERSION}" \
      org.opencontainers.image.s6-overlay-version="${S6_OVERLAY_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/HEJingshen/ocserv-docker"

# 配置清华源（文件不存在时跳过，避免 set -e 终止构建）
RUN [ -f /etc/apt/sources.list.d/debian.sources ] && \
    sed -i 's@//.*deb.debian.org@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list.d/debian.sources || true

# 安装运行时依赖（最小化：仅 ocserv 运行 + procps 用于健康检查）
RUN set -e; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    libgnutls30t64 libev4 libreadline8t64 libtasn1-6 \
    libpam0g liblz4-1 libseccomp2 libnl-route-3-200 \
    libkrb5-3 libradcli4 libcurl3t64-gnutls libcjose0 \
    libjansson4 liboath0t64 libprotobuf-c1 libtalloc2 \
    libllhttp9.2 iproute2 iptables ca-certificates procps && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译产物
COPY --from=builder /out /.

# s6-overlay tarball 解压后即为 / 的 layout（官方设计），直接覆盖复制
COPY --from=builder /tmp/s6-out/ /.

# s6-overlay v3 工具在 /command/ 目录，加入 PATH 使 docker exec 可用
ENV PATH="/command:${PATH}"

# ================= s6-overlay 服务定义 =================
# 合并目录创建 + 服务类型声明 + 依赖链接为单层，减少镜像层数
RUN set -e; \
    mkdir -p /etc/ocserv /run/ocserv /var/log/ocserv \
             /etc/s6-overlay/s6-rc.d/ocserv-init \
             /etc/s6-overlay/s6-rc.d/ocserv \
             /etc/s6-overlay/s6-rc.d/ocserv/dependencies.d \
             /etc/s6-overlay/s6-rc.d/user/contents.d && \
    echo "oneshot" > /etc/s6-overlay/s6-rc.d/ocserv-init/type && \
    echo "longrun" > /etc/s6-overlay/s6-rc.d/ocserv/type && \
    ln -s ../ocserv-init /etc/s6-overlay/s6-rc.d/ocserv/dependencies.d/ && \
    ln -s ../ocserv-init /etc/s6-overlay/s6-rc.d/user/contents.d/ && \
    ln -s ../ocserv /etc/s6-overlay/s6-rc.d/user/contents.d/

# 合并服务脚本写入为单层
# s6-overlay v3 约定：oneshot 服务的 up 文件由 s6-rc-oneshot-run 以 execline 语法解析，
# 因此 up 文件必须使用 execline 格式（#!/command/execlineb），而非 shell 脚本。
# 初始化逻辑（含 NAT/转发规则）提取为独立 shell 脚本，由 up 文件通过 execline 调用。
RUN <<'ENDSCRIPT'
#!/bin/sh
set -e

# 初始化逻辑独立为 shell 脚本（含 iptables NAT/转发规则配置）
cat > /etc/ocserv/s6-init.sh << 'INITFILE'
#!/bin/sh
set -e
echo "=== ocserv initialization start ==="

# ---- 配置检查 ----
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

# ---- iptables NAT/转发规则（VPN 客户端上网必需） ----
# 从 ocserv.conf 读取 VPN IPv4 子网，用于精确匹配 NAT 规则
# ocserv.conf 支持两种格式：
#   格式A: ipv4-network = 10.10.10.0/24       （CIDR 单行写法）
#   格式B: ipv4-network = 10.10.10.0           （两行写法，需配合 ipv4-netmask）
#          ipv4-netmask = 255.255.255.0

# 提取 ipv4-network 的值（处理 "key = value" 和 "key=value" 两种写法）
VPN_NETWORK_VAL=$(grep -E '^[[:space:]]*ipv4-network[[:space:]]*=' /etc/ocserv/ocserv.conf 2>/dev/null \
    | head -1 | sed 's/^[^=]*=[[:space:]]*//')

if [ -n "${VPN_NETWORK_VAL}" ]; then
    case "${VPN_NETWORK_VAL}" in
        */*)
            # 格式A：值已包含 CIDR 后缀，直接使用
            VPN_CIDR="${VPN_NETWORK_VAL}"
            ;;
        *)
            # 格式B：需配合 ipv4-netmask 计算前缀长度
            VPN_NETMASK_VAL=$(grep -E '^[[:space:]]*ipv4-netmask[[:space:]]*=' /etc/ocserv/ocserv.conf 2>/dev/null \
                | head -1 | sed 's/^[^=]*=[[:space:]]*//')
            if [ -n "${VPN_NETMASK_VAL}" ]; then
                # 纯 shell 将点分十进制 netmask 转换为 CIDR 前缀长度（无需 ipcalc）
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
                        0)   ;;
                        *)   _prefix=0; break ;;
                    esac
                done
                if [ "${_prefix}" -gt 0 ]; then
                    VPN_CIDR="${VPN_NETWORK_VAL}/${_prefix}"
                fi
            fi
            ;;
    esac
fi

# 若无法从配置解析子网，使用 ocserv 默认值
if [ -z "${VPN_CIDR}" ]; then
    VPN_CIDR="10.10.10.0/24"
    echo "WARNING: Unable to parse VPN subnet from config, using default ${VPN_CIDR}"
fi

echo "Configuring iptables for VPN subnet: ${VPN_CIDR}"

# 获取默认出口接口（容器内通常为 eth0）
DEFAULT_IF=$(ip route | awk '/default/ {print $5; exit}')
if [ -z "${DEFAULT_IF}" ]; then
    DEFAULT_IF="eth0"
fi

echo "Default outbound interface: ${DEFAULT_IF}"

# 允许 VPN 子网转发流量
iptables -C FORWARD -s "${VPN_CIDR}" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -s "${VPN_CIDR}" -j ACCEPT
iptables -C FORWARD -d "${VPN_CIDR}" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -d "${VPN_CIDR}" -j ACCEPT

# NAT 伪装：将 VPN 客户端源 IP 转换为容器出口 IP
iptables -t nat -C POSTROUTING -s "${VPN_CIDR}" -o "${DEFAULT_IF}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "${VPN_CIDR}" -o "${DEFAULT_IF}" -j MASQUERADE

echo "iptables rules configured successfully"
echo "=== ocserv initialization complete ==="
exit 0
INITFILE
chmod +x /etc/ocserv/s6-init.sh

# up 文件使用 execline 语法，调用独立 shell 脚本
printf '#!/command/execlineb -P\n/etc/ocserv/s6-init.sh\n' \
    > /etc/s6-overlay/s6-rc.d/ocserv-init/up
chmod +x /etc/s6-overlay/s6-rc.d/ocserv-init/up

printf '#!/bin/sh\nexec ocserv -c /etc/ocserv/ocserv.conf -f\n' \
    > /etc/s6-overlay/s6-rc.d/ocserv/run
chmod +x /etc/s6-overlay/s6-rc.d/ocserv/run
ENDSCRIPT

EXPOSE 30443/tcp 30443/udp

# 健康检查：通过 ss 检查 TCP 端口监听状态（比 pgrep 更可靠）
# ocserv 启用 isolate-workers + run-as-user 后，进程名可能不再精确匹配 "ocserv"，
# 导致 pgrep -x 误判；而端口监听直接验证服务可用性
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ss -tln | grep -q ':30443' || exit 1

# s6 接管 PID 1，自动处理信号转发、僵尸回收、服务依赖
ENTRYPOINT ["/init"]