# ocserv-docker

[![Build & Pull](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build.yml/badge.svg)](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build.yml)
[![Build & Pull](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build-exporter.yml/badge.svg)](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build-exporter.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/kingsonho/ocserv)](https://hub.docker.com/r/kingsonho/ocserv)
[![Docker Pulls](https://img.shields.io/docker/pulls/kingsonho/ocserv-exporter)](https://hub.docker.com/r/kingsonho/ocserv-exporter)
[![Docker Image Version](https://img.shields.io/docker/v/kingsonho/ocserv?sort=semver)](https://hub.docker.com/r/kingsonho/ocserv/tags)

基于 Docker 的 OpenConnect VPN Server（ocserv），支持 **多架构**（amd64 / arm64），内置 **s6-overlay 进程管理**，可选 **Prometheus + Grafana 监控栈**。

---

## 目录

- [一、部署前准备](#一部署前准备)
- [二、单独部署 ocserv](#二单独部署-ocserv)
- [三、与监控系统一起部署](#三与监控系统一起部署)
- [四、自行构建镜像](#四自行构建镜像)
- [五、配置参考](#五配置参考)
- [六、故障排查](#六故障排查)
- [七、功能模块指南](#七功能模块指南)

---

## 一、部署前准备

### 1.1 环境要求

| 项目 | 要求 |
|:--|:--|
| 操作系统 | Linux（Debian / Ubuntu / CentOS / Rocky / Alma 等） |
| CPU 架构 | x86_64 或 ARM64 |
| 内核模块 | `tun`（`/dev/net/tun` 存在） |
| 内存 | 仅 VPN ≥ 64MB；VPN + 监控 ≥ 512MB |
| 端口 | TCP 443 + UDP 443（VPN）；8443（监控，可选） |

### 1.2 克隆项目

```bash
git clone https://github.com/HEJingshen/ocserv-docker.git
cd ocserv-docker
```

后续命令默认都在项目根目录执行。

### 1.3 安装 Docker

```bash
sudo bash install-docker.sh -y
```

脚本自动检测发行版、选择最快镜像源、安装 Docker CE + Compose。

如果还没有克隆项目，也可以先远程下载安装脚本后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/HEJingshen/ocserv-docker/main/install-docker.sh -o install-docker.sh
sudo bash install-docker.sh -y
```

### 1.4 准备 SSL 证书

生产环境推荐使用 Let's Encrypt。申请前请确认：

- 域名 `your.domain.com` 的 A/AAAA 记录已指向当前服务器
- 服务器 TCP 80 端口已放通
- 申请证书时没有其他服务占用 80 端口；`certbot --standalone` 会临时监听 80 端口

```bash
sudo apt install certbot
sudo certbot certonly --standalone -d your.domain.com
```

证书路径：`/etc/letsencrypt/live/your.domain.com/fullchain.pem` 和 `privkey.pem`

CentOS / Rocky / Alma 等发行版请使用对应包管理器安装 `certbot`。

**自签名证书（仅测试）**

默认生产部署会从 `/etc/letsencrypt/live/${DOMAIN}` 挂载证书。如果只做本地或内网测试，可以在仓库内生成自签证书，并用 `docker-compose.override.yml` 覆盖 ocserv 的证书挂载：

```bash
DOMAIN=your.domain.com
mkdir -p "config/certs/${DOMAIN}"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "config/certs/${DOMAIN}/privkey.pem" \
  -out "config/certs/${DOMAIN}/fullchain.pem" \
  -subj "/CN=${DOMAIN}"
```

创建 `docker-compose.override.yml`：

```yaml
services:
  ocserv:
    volumes:
      - ./config/ocserv.conf:/etc/ocserv/ocserv.conf:ro
      - ./config/auth:/etc/ocserv/auth:rw
      - ./config/certs/${DOMAIN}/fullchain.pem:/etc/ocserv/fullchain.pem:ro
      - ./config/certs/${DOMAIN}/privkey.pem:/etc/ocserv/privkey.pem:ro
      - ./logs:/var/log/ocserv
      - ocserv-socket:/var/run
```

自签名证书通常会触发客户端证书警告，需要在客户端手动信任。监控栈的 Nginx 默认仍使用 `/etc/letsencrypt/live/${DOMAIN}`；如果监控也要使用自签证书，请将自签证书按 `live/${DOMAIN}/fullchain.pem` 和 `live/${DOMAIN}/privkey.pem` 的结构放到某个目录，并在 `.env` 中将 `SSL_CERT_DIR` 指向该目录。

---

## 二、单独部署 ocserv

### 2.1 配置环境变量

即使是单独部署 ocserv（不启用监控），也需要配置 `.env` 文件：

```bash
cp .env.example .env
vim .env
```

`.env.example` 中的变量已按部署方式分为两部分，单独部署只需关注 **「基础部署配置」**：

| 变量 | 说明 | 默认值 |
|:--|:--|:--|
| `DOMAIN` | 服务器域名，也会渲染为 ocserv `default-domain` | `your.domain.com` |
| `OCSERV_PORT` | VPN 服务对外端口（宿主机） | `443` |
| `OCSERV_IMAGE` | ocserv 镜像及版本 | `kingsonho/ocserv:latest` |
| `LOG_MAX_SIZE` / `LOG_MAX_FILE` | 日志轮转配置 | `10m` / `3` |
| `HEALTH_*` | 健康检查参数 | 30s / 5s / 3 / 15s |

**至少需修改**：将 `DOMAIN` 替换为实际域名，如需更改端口则修改 `OCSERV_PORT`。

### 2.2 准备配置

```bash
mkdir -p logs
mkdir -p config/auth
touch config/auth/ocpasswd
chmod 700 config/auth
chmod 600 config/auth/ocpasswd
./scripts/render-ocserv-conf.sh
```

仓库已提供 `config/ocserv.conf.template` 作为完整配置模板。`DOMAIN` 从 `.env` 渲染到 `default-domain` 后生成 `config/ocserv.conf`，容器只读挂载生成后的配置。如需调整 ocserv 参数，先修改 `config/ocserv.conf.template`，再重新运行 `./scripts/render-ocserv-conf.sh`。

启动前可先检查 Compose 配置和证书挂载路径：

```bash
docker compose config
DOMAIN=$(awk -F= '/^DOMAIN=/{print $2}' .env)
sudo ls -l "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
```

### 2.3 启动服务

```bash
docker compose up -d
```

容器启动时 s6-overlay 自动完成：基础文件检查 → iptables NAT/转发规则 → 启动 ocserv。配置语法错误会通过容器日志暴露。

### 2.4 创建用户

```bash
docker exec -it -u 0 ocserv ocpasswd -c /etc/ocserv/auth/ocpasswd username
```

`config/auth` 目录以读写方式挂载到容器内 `/etc/ocserv/auth`。`ocpasswd` 会通过临时文件和原子替换更新密码文件，因此需要挂载整个可写目录，而不是只挂载单个 `ocpasswd` 文件。建议显式使用 `-u 0` 以 root 身份执行，避免容器默认用户或 user namespace 配置导致无法写入。

### 2.5 验证服务

```bash
docker inspect --format='{{.State.Health.Status}}' ocserv   # 预期: healthy
docker compose logs -f ocserv
docker exec ocserv occtl show users
```

### 2.6 客户端连接

连接地址：

- 默认 443 端口：`https://your.domain.com`
- 如果 `.env` 中 `OCSERV_PORT` 不是 `443`：`https://your.domain.com:${OCSERV_PORT}`

| 平台 | 客户端 |
|:--|:--|
| Windows / macOS | [Cisco AnyConnect](https://www.cisco.com/c/en/us/products/security/anyconnect-secure-mobility-client/) |
| macOS | `brew install openconnect-gui` |
| Linux | `apt install openconnect` |
| iOS / Android | App Store / Google Play 搜索 "AnyConnect" |

**Linux 命令行**：

```bash
sudo openconnect -b https://your.domain.com --user=username
# 非 443 端口:
sudo openconnect -b "https://your.domain.com:${OCSERV_PORT}" --user=username
```

### 2.7 常用命令

| 操作 | 命令 |
|:--|:--|
| 启动 | `docker compose up -d` |
| 停止 | `docker compose down` |
| 重启 | `docker compose restart` |
| 查看日志 | `docker compose logs -f ocserv` |
| 在线用户 | `docker exec ocserv occtl show users` |
| 服务状态 | `docker exec ocserv occtl show status` |
| 重载配置 | `docker exec ocserv occtl reload` |
| 删除用户 | `docker exec -it -u 0 ocserv ocpasswd -d /etc/ocserv/auth/ocpasswd username` |

---

## 三、与监控系统一起部署

### 3.1 架构概览

```
ocserv → exporter (Unix socket) → Prometheus (scrape) → Grafana (展示)
                                                          ↑
                                                    Nginx (HTTPS :8443)
                                                    /grafana/  /prometheus/
```

- **exporter**：通过 `occtl` 采集会话数、账号数、流量、运行时长
- **Prometheus**：监控编排默认每 10 秒拉取指标
- **Grafana**：预置 Overview 与 Sessions 两块看板，默认总览不查询高基数会话明细
- **Nginx**：HTTPS 反向代理，子路径分发

### 3.2 配置环境变量

```bash
cp .env.example .env
vim .env
```

`.env.example` 已按部署方式分为两部分：

- **「基础部署配置」** — 单独部署 VPN 时的变量（与 Section 二共享）
- **「附加监控配置」** — 仅在启用监控栈时需关注的变量

**基础部署中必须修改**：

| 变量 | 说明 | 示例 |
|:--|:--|:--|
| `DOMAIN` | 服务器域名 | `vpn.example.com` |

**附加监控中必须修改**：

| 变量 | 说明 | 示例 |
|:--|:--|:--|
| `GF_ADMIN_PASSWORD` | Grafana 密码 | `YourStrongPassword123!` |
| `SSL_CERT_DIR` | SSL 证书目录（Nginx 使用） | `/etc/letsencrypt` |

Nginx 启动时会严格校验 `DOMAIN`、`MONITORING_PORT`、TLS 证书、`.htpasswd` 和生成后的配置；任一项不合法都会阻止容器启动。

### 3.3 生成认证文件

```bash
echo "admin:$(openssl passwd -apr1 'YourPrometheusPassword')" > nginx/.htpasswd
```

`nginx/.htpasswd` 必须存在且非空；同时请确认 `/etc/letsencrypt/live/${DOMAIN}/fullchain.pem` 和 `privkey.pem` 与 `.env` 中的 `DOMAIN` 匹配。

### 3.4 准备基础配置

即使直接部署完整监控栈，也需要先准备 ocserv 的日志目录、密码目录和渲染后的主配置：

```bash
mkdir -p logs
mkdir -p config/auth
touch config/auth/ocpasswd
chmod 700 config/auth
chmod 600 config/auth/ocpasswd
./scripts/render-ocserv-conf.sh
```

启动前检查 Compose 配置、监控认证文件和证书目录：

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml config
test -s nginx/.htpasswd
test -w nginx/conf.d
DOMAIN=$(awk -F= '/^DOMAIN=/{print $2}' .env)
SSL_CERT_DIR=$(awk -F= '/^SSL_CERT_DIR=/{print $2}' .env)
sudo ls -l "${SSL_CERT_DIR:-/etc/letsencrypt}/live/${DOMAIN}/fullchain.pem" "${SSL_CERT_DIR:-/etc/letsencrypt}/live/${DOMAIN}/privkey.pem"
```

### 3.5 启动完整栈

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

验证：

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml ps
docker exec nginx-proxy nginx -t
```

### 3.6 访问监控

| 服务 | 地址 | 认证 |
|:--|:--|:--|
| Grafana | `https://your.domain.com:8443/grafana/` | admin / `${GF_ADMIN_PASSWORD}` |
| Prometheus | `https://your.domain.com:8443/prometheus/` | htpasswd |

如果 `.env` 中 `MONITORING_PORT` 不是 `8443`，请将地址中的端口替换为实际值。

**内置仪表盘面板**：活跃会话数、活跃账号数、服务状态、运行时长、版本信息、流量速率（RX/TX）、每会话流量、用户排行、连接时长。

**Prometheus 常用查询**：

```
ocserv_active_sessions                     # 当前在线会话数
ocserv_active_accounts                     # 当前唯一账号数
ocserv_bytes_rx_rate_bytes_per_second      # 当前接收速率（字节/秒）
ocserv_up                                  # 服务是否在线
```

### 3.7 部署 Fail2Ban

保护监控端点免受暴力破解（10 分钟内 5 次失败 → 封禁 1 小时）：

```bash
./setup-fail2ban.sh
sudo fail2ban-client status nginx-auth      # 查看状态
sudo fail2ban-client set nginx-auth unbanip <IP>   # 手动解封
```

### 3.8 数据持久化

Prometheus 和 Grafana 数据通过 Docker 卷持久化，容器重建不丢失。彻底清理：

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down -v
```

---

## 四、自行构建镜像

### 4.1 准备构建素材

将以下文件放入 `src/` 目录：

```bash
mkdir -p src && cd src
wget https://www.infradead.org/ocserv/ocserv-1.4.2.tar.xz
wget https://github.com/just-containers/s6-overlay/releases/download/v3.2.3.0/s6-overlay-noarch.tar.xz
wget https://github.com/just-containers/s6-overlay/releases/download/v3.2.3.0/s6-overlay-x86_64.tar.xz
wget https://github.com/just-containers/s6-overlay/releases/download/v3.2.3.0/s6-overlay-aarch64.tar.xz
cd ..
```

当前 `Dockerfile` 会无条件复制 `s6-overlay-noarch.tar.xz`、`s6-overlay-x86_64.tar.xz` 和 `s6-overlay-aarch64.tar.xz`。即使只构建 amd64，也需要三个 s6-overlay 文件都存在，否则 Docker 构建上下文校验会失败。

### 4.2 构建 ocserv 镜像

```bash
# 基础构建
docker buildx build -t ocserv:local .

# 指定参数
docker buildx build \
  --build-arg OCSERV_VERSION=1.4.2 \
  --build-arg S6_OVERLAY_VERSION=3.2.3.0 \
  --build-arg BASE_IMAGE=debian:trixie-slim \
  -t ocserv:1.4.2 .
```

构建后在 `.env` 中设置 `OCSERV_IMAGE=ocserv:local`。

**构建参数**：

| ARG | 默认值 | 说明 |
|:--|:--|:--|
| `OCSERV_VERSION` | `1.4.2` | ocserv 版本 |
| `S6_OVERLAY_VERSION` | `3.2.3.0` | s6-overlay 版本 |
| `BASE_IMAGE` | `debian:trixie-slim` | 基础镜像 |
| `USE_TUNA_MIRROR` | `true` | 是否使用清华 apt 源；GitHub Actions 中设为 `false` |

**多架构构建**：

```bash
mkdir -p src
wget -O src/ocserv-1.4.2.tar.xz https://www.infradead.org/ocserv/ocserv-1.4.2.tar.xz
wget -O src/s6-overlay-noarch.tar.xz https://github.com/just-containers/s6-overlay/releases/download/v3.2.3.0/s6-overlay-noarch.tar.xz
wget -O src/s6-overlay-x86_64.tar.xz https://github.com/just-containers/s6-overlay/releases/download/v3.2.3.0/s6-overlay-x86_64.tar.xz
wget -O src/s6-overlay-aarch64.tar.xz https://github.com/just-containers/s6-overlay/releases/download/v3.2.3.0/s6-overlay-aarch64.tar.xz

docker buildx build --platform linux/amd64,linux/arm64 --push \
  -t registry.example.com/ocserv:1.4.2 .
```

**验证**：`docker run --rm --entrypoint ocserv ocserv:local --version`

### 4.3 构建 Exporter 镜像

```bash
docker buildx build -f exporter/Dockerfile -t ocserv-exporter:local .
```

构建后在 `.env` 中设置 `EXPORTER_IMAGE=ocserv-exporter:local`。

**验证**：`docker run --rm --entrypoint occtl ocserv-exporter:local --version`

### 4.4 自定义基础镜像

```bash
docker buildx build --build-arg BASE_IMAGE=ubuntu:24.04 -t ocserv:ubuntu .
```

> ⚠️ 非 Debian 基础镜像需调整依赖包名并验证 s6-overlay 兼容性。

### 4.5 Alpine 可行性镜像（实验）

仓库提供独立的 Alpine 构建入口，不会替换默认 Debian 镜像：

```bash
# Alpine slim：生产灰度优先验证目标，保留 LZ4、plain auth、occtl、iptables NAT、s6
docker buildx build \
  -f Dockerfile.alpine \
  --build-arg ALPINE_FLAVOR=slim \
  --build-arg S6_SOURCE=auto \
  -t ocserv:1.4.2-alpine-slim .

# Alpine full：能力验证目标，不建议直接作为首批生产候选
docker buildx build \
  -f Dockerfile.alpine \
  --build-arg ALPINE_FLAVOR=full \
  --build-arg S6_SOURCE=auto \
  -t ocserv:1.4.2-alpine-full .

# Alpine exporter
docker buildx build \
  -f exporter/Dockerfile.alpine \
  -t ocserv-exporter:1.4.2-alpine .
```

**Alpine 构建参数**：

| ARG | 默认值 | 说明 |
|:--|:--|:--|
| `BASE_IMAGE` | `alpine:3.22` | Alpine 基础镜像 |
| `ALPINE_FLAVOR` | `slim` | `slim` 或 `full` |
| `S6_SOURCE` | `auto` | `auto`、`apk` 或 `tarball` |
| `APK_MIRROR` | `https://dl-cdn.alpinelinux.org/alpine` | Alpine apk 源 |

`S6_SOURCE=auto` 会优先尝试 Alpine 仓库中的 `s6-overlay` 包，若 `/init` 不可用则回退到 `src/` 中的 s6-overlay tarball。`S6_SOURCE=apk` 用于强制验证 Alpine 仓库包；`S6_SOURCE=tarball` 用于和现有 Debian 镜像的 s6-overlay 来源对照。

Alpine `slim` 会禁用 utmp 编译能力，渲染配置时需要同步关闭 `use-utmp`：

```bash
OCSERV_DISABLE_UTMP=true ./scripts/render-ocserv-conf.sh
```

Alpine `full` 会强制保留 PAM、GSSAPI/Kerberos、seccomp，并自动探测 RADIUS 与 OTP/liboath。若 Alpine 稳定仓库缺少对应开发包，构建不会补源码依赖，相关能力需要在可行性报告中标记为未等价。

---

## 五、配置参考

### 5.1 核心配置项

| 配置项 | 说明 | 默认值 |
|:--|:--|:--|
| `tcp-port` | TCP 端口 | `443` |
| `udp-port` | UDP 端口（DTLS） | `443` |
| `auth` | 认证方式 | `plain[passwd=/etc/ocserv/auth/ocpasswd]` |
| `server-cert` | TLS 证书 | `/etc/ocserv/fullchain.pem` |
| `server-key` | TLS 私钥 | `/etc/ocserv/privkey.pem` |
| `ipv4-network` | VPN IP 段 | `10.10.10.0` |
| `ipv4-netmask` | 子网掩码 | `255.255.255.0` |
| `dns` | 推送 DNS | `8.8.8.8` |
| `max-clients` | 最大客户端（0=不限） | `0` |
| `keepalive` | 心跳间隔（秒） | `30` |
| `dpd` | 死连接检测（秒） | `90` |
| `compression` | 启用压缩 | `true` |
| `try-mtu-discovery` | MTU 自动发现 | `true` |
| `isolate-workers` | 隔离工作进程 | `true` |
| `run-as-user` | 运行用户 | `nobody` |

完整配置模板见 `config/ocserv.conf.template`，运行时配置由 `scripts/render-ocserv-conf.sh` 生成到 `config/ocserv.conf`。

### 5.2 卷挂载

| 宿主机路径 | 容器路径 | 模式 | 说明 |
|:--|:--|:--|:--|
| `./config/ocserv.conf` | `/etc/ocserv/ocserv.conf` | ro | 渲染后的主配置 |
| `/etc/letsencrypt/live/${DOMAIN}/fullchain.pem` | `/etc/ocserv/fullchain.pem` | ro | 证书 |
| `/etc/letsencrypt/live/${DOMAIN}/privkey.pem` | `/etc/ocserv/privkey.pem` | ro | 私钥 |
| `./config/auth` | `/etc/ocserv/auth` | rw | 用户密码目录 |
| `./logs` | `/var/log/ocserv` | rw | 日志 |

### 5.3 容器权限

| 配置 | 作用 |
|:--|:--|
| `cap_add: NET_ADMIN` | 操作网络栈（iptables NAT） |
| `devices: /dev/net/tun` | TUN 隧道设备 |
| `sysctls: net.ipv4.ip_forward=1` | 启用 IP 转发 |

### 5.4 环境变量

完整列表见 `.env.example`。变量已按部署方式分为两组：

**基础部署配置（docker-compose.yml）**

| 变量 | 说明 | 默认值 |
|:--|:--|:--|
| `TZ` | 时区设置 | `Asia/Shanghai` |
| `DOMAIN` | 服务器域名，也会渲染为 ocserv `default-domain` | `your.domain.com` |
| `OCSERV_PORT` | VPN 服务对外端口（宿主机） | `443` |
| `OCSERV_IMAGE` | ocserv 镜像及版本 | `kingsonho/ocserv:latest` |
| `LOG_MAX_SIZE` | 日志文件最大大小 | `10m` |
| `LOG_MAX_FILE` | 日志文件保留数量 | `3` |
| `HEALTH_INTERVAL` | 健康检查间隔 | `30s` |
| `HEALTH_TIMEOUT` | 健康检查超时 | `5s` |
| `HEALTH_RETRIES` | 健康检查重试次数 | `3` |
| `HEALTH_START_PERIOD` | 健康检查启动宽限期 | `15s` |

**附加监控配置（docker-compose.monitoring.yml，可选）**

| 变量 | 说明 | 默认值 |
|:--|:--|:--|
| `MONITORING_PORT` | 监控面板对外端口（HTTPS） | `8443` |
| `NETWORK_NAME` | Docker 网络名称 | `monitor-net` |
| `EXPORTER_IMAGE` | ocserv-exporter 镜像 | `kingsonho/ocserv-exporter:latest` |
| `PROMETHEUS_IMAGE` | Prometheus 镜像 | `prom/prometheus:latest` |
| `GRAFANA_IMAGE` | Grafana 镜像 | `grafana/grafana:latest` |
| `NGINX_IMAGE` | Nginx 镜像 | `nginx:alpine` |
| `GF_ADMIN_PASSWORD` | Grafana 管理员密码 | `admin123` |
| `GF_ALLOW_SIGN_UP` | 允许用户注册 | `false` |
| `GF_DASHBOARDS_MIN_REFRESH_INTERVAL` | Grafana 看板最小刷新间隔，生产默认防止低于 30s | `30s` |
| `GF_ANALYTICS_REPORTING_ENABLED` | Grafana 匿名统计上报 | `false` |
| `GF_ANALYTICS_CHECK_FOR_UPDATES` | Grafana 版本更新检查 | `false` |
| `GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES` | Grafana 插件更新检查 | `false` |
| `GF_UNIFIED_ALERTING_EXECUTE_ALERTS` | Grafana 内置告警执行；不使用 Grafana 告警时建议关闭 | `false` |
| `GF_DATAPROXY_RESPONSE_LIMIT` | Grafana data proxy 单次响应大小限制（字节） | `10485760` |
| `GRAFANA_MEM_LIMIT` | Grafana 容器内存上限；低于 512m 时偶发 502/OOM 风险更高 | `512m` |
| `GRAFANA_MEMSWAP_LIMIT` | Grafana 容器内存+swap 上限 | `512m` |
| `GRAFANA_CPUS` | Grafana 容器 CPU 上限 | `1.00` |
| `METRICS_PORT` | 指标导出端口 | `9100` |
| `EXPORTER_INTERVAL_SECONDS` | exporter 采集间隔；实时优先 5s，均衡生产 10s，资源优先 15s | `10` |
| `OCCTL_TIMEOUT_SECONDS` | 单次 `occtl` 调用超时；建议小于 Prometheus `scrape_timeout` | `2` |
| `EXPORTER_ENABLE_SESSION_DETAIL_METRICS` | 是否导出 `ocserv_user_*` 高基数会话明细指标 | `false` |
| `SSL_CERT_DIR` | SSL 证书目录 | `/etc/letsencrypt` |

### 5.5 最小可用配置

修改以下 3 项即可启动：

```ini
auth = "plain[passwd=/etc/ocserv/auth/ocpasswd]"
server-cert = /etc/ocserv/fullchain.pem
server-key = /etc/ocserv/privkey.pem
```

---

## 六、故障排查

### 6.1 服务无法启动

```bash
docker compose logs ocserv
DOMAIN=$(awk -F= '/^DOMAIN=/{print $2}' .env)
sudo ls -la "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
OCSERV_PORT=$(awk -F= '/^OCSERV_PORT=/{print $2}' .env)
sudo ss -tlnp | grep ":${OCSERV_PORT:-443}"
```

| 原因 | 解决 |
|:--|:--|
| 证书缺失 | 确认证书文件存在且路径正确 |
| 配置语法错误 | 先修正 `config/ocserv.conf.template`，再运行 `./scripts/render-ocserv-conf.sh` |
| TUN 设备不存在 | `sudo modprobe tun` |
| 端口被占用 | 修改 `.env` 中 `OCSERV_PORT` |

也可以先检查 Compose 最终渲染结果，确认 `.env`、证书挂载和端口映射符合预期：

```bash
docker compose config
DOMAIN=$(awk -F= '/^DOMAIN=/{print $2}' .env)
sudo ls -l "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
```

### 6.2 客户端无法连接

```bash
docker inspect --format='{{.State.Health.Status}}' ocserv
OCSERV_PORT=$(awk -F= '/^OCSERV_PORT=/{print $2}' .env)
sudo ss -tlnp | grep ":${OCSERV_PORT:-443}"
sudo ss -ulnp | grep ":${OCSERV_PORT:-443}"
sudo ufw allow "${OCSERV_PORT:-443}/tcp"
sudo ufw allow "${OCSERV_PORT:-443}/udp"
```

| 原因 | 解决 |
|:--|:--|
| 防火墙阻止 | 开放 TCP/UDP `${OCSERV_PORT:-443}` |
| 用户不存在 | 使用 `ocpasswd` 添加 |
| 证书不匹配 | 证书 CN/SAN 需包含连接时的域名或 IP |

### 6.3 `ocpasswd` 提示无法写入

如果执行以下命令时返回 `Cannot write to '/etc/ocserv/ocpasswd'.`，通常说明旧版本使用了单文件 bind mount。`test -w /etc/ocserv/ocpasswd` 可能仍然成功，因为文件本身可写；但 `ocpasswd` 更新时会创建临时文件并原子替换目标文件，单文件挂载点无法被这种方式覆盖。

```bash
docker exec -it -u 0 ocserv ocpasswd -c /etc/ocserv/auth/ocpasswd username
```

先确认运行中的容器实际挂载的是密码目录，并且为可写：

```bash
docker inspect ocserv \
  --format '{{range .Mounts}}{{if eq .Destination "/etc/ocserv/auth"}}Source={{.Source}} Destination={{.Destination}} RW={{.RW}}{{end}}{{end}}'
```

预期输出包含 `Destination=/etc/ocserv/auth RW=true`。如果仍显示 `/etc/ocserv/ocpasswd`，请切换到目录挂载：

```yaml
- ./config/auth:/etc/ocserv/auth:rw
```

并确认 `config/ocserv.conf.template` 和 `config/ocserv.conf` 使用同一路径：

```ini
auth = "plain[passwd=/etc/ocserv/auth/ocpasswd]"
```

检查容器内目录和密码文件是否存在且可写：

```bash
docker exec -u 0 ocserv ls -ld /etc/ocserv/auth
docker exec -u 0 ocserv ls -l /etc/ocserv/auth/ocpasswd
docker exec -u 0 ocserv test -d /etc/ocserv/auth
docker exec -u 0 ocserv test -w /etc/ocserv/auth
docker exec -u 0 ocserv test -w /etc/ocserv/auth/ocpasswd
```

检查宿主机目录和文件权限：

```bash
ls -ld config/auth
ls -l config/auth/ocpasswd
test -d config/auth
test -f config/auth/ocpasswd
chmod 700 config/auth
chmod 600 config/auth/ocpasswd
```

从旧版 `config/ocpasswd` 迁移到目录挂载的最小恢复流程：

```bash
mkdir -p config/auth
if [ -f config/ocpasswd ] && [ ! -f config/auth/ocpasswd ]; then cp config/ocpasswd config/auth/ocpasswd; fi
touch config/auth/ocpasswd
chmod 700 config/auth
chmod 600 config/auth/ocpasswd
./scripts/render-ocserv-conf.sh
docker compose up -d --force-recreate ocserv
docker exec -it -u 0 ocserv ocpasswd -c /etc/ocserv/auth/ocpasswd username
```

如果暂时不方便重建容器，可先用以下临时方式在旧单文件挂载上创建用户：先在容器内可写目录生成新密码文件，再把内容写回挂载文件。

```bash
docker exec -it -u 0 ocserv sh -c '
  cp /etc/ocserv/ocpasswd /tmp/ocpasswd &&
  ocpasswd -c /tmp/ocpasswd username &&
  cat /tmp/ocpasswd > /etc/ocserv/ocpasswd
'
```

常见原因：

| 原因 | 解决 |
|:--|:--|
| 旧版单文件挂载 `/etc/ocserv/ocpasswd` | 改为挂载 `./config/auth:/etc/ocserv/auth:rw` 并重建容器 |
| `config/auth/ocpasswd` 不存在或 `config/auth` 被创建成文件 | 修正为目录加文件：`mkdir -p config/auth && touch config/auth/ocpasswd` |
| 宿主机权限过窄 | 执行 `chmod 700 config/auth && chmod 600 config/auth/ocpasswd` 后使用 `-u 0` 创建用户 |
| rootless Docker 或 user namespace 映射限制 | 调整宿主机目录所有者映射，确保容器 root 对 `config/auth` 目录可写 |
| SELinux 拦截绑定挂载写入 | 在启用 SELinux 的系统上为挂载添加合适标签，或按发行版策略放行该路径 |

### 6.4 连接后无法上网

```bash
sysctl net.ipv4.ip_forward
docker exec ocserv iptables -t nat -L POSTROUTING -n
docker compose restart ocserv
```

| 原因 | 解决 |
|:--|:--|
| 内核转发未启用 | `sudo sysctl -w net.ipv4.ip_forward=1` |
| NAT 规则异常 | 重启容器重新初始化 iptables |

### 6.5 监控面板无法访问

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml ps
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml config
docker logs nginx-proxy
test -s nginx/.htpasswd
test -w nginx/conf.d
DOMAIN=$(awk -F= '/^DOMAIN=/{print $2}' .env)
SSL_CERT_DIR=$(awk -F= '/^SSL_CERT_DIR=/{print $2}' .env)
sudo ls -ld "${SSL_CERT_DIR:-/etc/letsencrypt}/live/${DOMAIN}"
```

| 原因 | 解决 |
|:--|:--|
| `DOMAIN` 未配置 | 在 `.env` 中设置 |
| `MONITORING_PORT` 非法 | 设置为 `1-65535` 范围内的数字 |
| htpasswd 缺失或为空 | 运行步骤 3.3 生成非空 `nginx/.htpasswd` |
| `nginx/conf.d` 不可写 | 确认 `nginx/conf.d` 是目录且当前用户或 Docker 可写 |
| 证书路径错误 | 确认 `SSL_CERT_DIR/live/${DOMAIN}` 目录存在，且包含 `fullchain.pem` 和 `privkey.pem` |
| Nginx 配置生成失败 | 检查 `docker logs nginx-proxy` 中的 entrypoint 错误，并修正 `.env`、证书或模板 |

### 6.6 Exporter 采集异常

```bash
docker logs ocserv-exporter
docker exec ocserv ls -la /var/run/occtl.socket
docker exec ocserv occtl -j show status
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml exec prometheus wget -qO- http://ocserv:9100/metrics
```

| 原因 | 解决 |
|:--|:--|
| socket 不存在 | 重启 ocserv 容器 |
| 版本不匹配 | 确保 exporter 与 ocserv 版本一致 |
| Prometheus 无法访问指标 | exporter 使用 `network_mode: service:ocserv` 与 ocserv 共用网络命名空间，因此 Prometheus 目标是 `ocserv:9100`，不需要也不应额外映射 exporter 端口 |

### 6.7 证书续期后处理

| 挂载方式 | 续期后操作 |
|:--|:--|
| 复制到 `config/` | 重新复制 + `docker compose restart ocserv` |
| 直接挂载 `/etc/letsencrypt/live/` | `docker compose restart ocserv` |

验证：

```bash
OCSERV_PORT=$(awk -F= '/^OCSERV_PORT=/{print $2}' .env)
DOMAIN=$(awk -F= '/^DOMAIN=/{print $2}' .env)
echo | openssl s_client -connect "${DOMAIN}:${OCSERV_PORT:-443}" 2>/dev/null | openssl x509 -noout -dates
```

---

## 七、功能模块指南

### 7.1 s6-overlay 进程管理

**启动流程**：

```
容器启动 → s6-overlay → ocserv-init (oneshot: 基础文件检查 + iptables) → ocserv (longrun)
```

**优势**：启动阶段先检查主配置文件是否存在、可读，并自动配置 iptables；容器启动后即可让客户端上网；进程异常由 s6-overlay 管理。ocserv 配置语法错误会在 `docker compose logs ocserv` 中暴露。

```bash
docker exec ocserv s6-rc list          # 查看服务列表
docker exec ocserv occtl reload        # 不重启容器重载配置
```

### 7.2 Prometheus Exporter

通过 `occtl -j` JSON 输出采集指标。exporter 镜像和监控编排默认每 10 秒采集一次，Grafana 默认最小刷新间隔为 30 秒，适合生产环境的均衡低压配置。

| 指标 | 类型 | 说明 |
|:--|:--|:--|
| `ocserv_up` | Gauge | 1=正常, 0=异常 |
| `ocserv_active_sessions` | Gauge | 活跃会话数 |
| `ocserv_active_accounts` | Gauge | 活跃唯一账号数 |
| `ocserv_uptime_seconds` | Gauge | 运行时长 |
| `ocserv_start_time_seconds` | Gauge | 服务启动时间戳 |
| `ocserv_sessions_total` | Gauge | 服务启动以来处理的总会话数 |
| `ocserv_authentication_failures_total` | Gauge | 服务启动以来认证失败总数 |
| `ocserv_banned_ips` | Gauge | 当前封禁 IP 数 |
| `ocserv_stats_*` | Gauge | 上次 stats reset 以来的会话、超时、错误关闭、认证失败和流量统计 |
| `ocserv_auth_time_*_seconds` | Gauge | 平均/最大认证耗时 |
| `ocserv_session_time_*_seconds` | Gauge | 平均/最大会话时长 |
| `ocserv_stats_bytes_rx/tx_total` | Gauge | `show status.raw_rx/raw_tx`，上次 stats reset 以来的累计流量，用于 Overview 的 Traffic Total 面板 |
| `ocserv_bytes_rx/tx_total` | Gauge | 当前在线会话累计收发流量求和，固定来自 `show users` 的每会话 `RX/TX` |
| `ocserv_bytes_rx/tx_rate_bytes_per_second` | Gauge | 实时收发速率（字节/秒） |
| `ocserv_user_bytes_rx/tx` | Gauge | 每会话流量；需启用 `EXPORTER_ENABLE_SESSION_DETAIL_METRICS=true` |
| `ocserv_user_bytes_rx/tx_rate_bytes_per_second` | Gauge | 每会话实时速率；需启用 `EXPORTER_ENABLE_SESSION_DETAIL_METRICS=true` |

默认只导出服务级和聚合指标，不导出 `ocserv_user_*` 高基数会话明细。需要用户排行、每会话表格或连接时长诊断时，在 `.env` 中设置 `EXPORTER_ENABLE_SESSION_DETAIL_METRICS=true` 并重建 exporter 容器。启用后会自动清理已断开用户的标签，防止指标泄漏。服务不可用时重置所有指标。

同一账号多设备同时连接时，`ocserv_active_sessions` 会按连接会话计数，`ocserv_active_accounts` 会按唯一账号计数。每会话指标使用 `session_id` 区分连接，即使两台设备位于同一 NAT 公网 IP 后也不会互相覆盖。

**指标重要性评估**：

| 指标 | 重要性 | 评估 |
|:--|:--|:--|
| `ocserv_up` | 关键 | 服务可用性核心指标，应保留 |
| `ocserv_active_sessions` | 关键 | 当前真实在线会话数 |
| `ocserv_active_accounts` | 高 | 区分同账号多设备场景，排障价值高 |
| `ocserv_bytes_rx/tx_rate_bytes_per_second` | 高 | 实时带宽面板核心指标 |
| `ocserv_sessions_total` / `ocserv_authentication_failures_total` / `ocserv_banned_ips` | 高 | 固定服务级指标，成本低，适合默认开启 |
| `ocserv_user_bytes_rx/tx` | 中高 | 每会话流量、排行、明细表依赖，标签基数随会话数增长，默认关闭 |
| `ocserv_user_connected_seconds` | 中高 | 连接时长排障有用，默认关闭 |
| `ocserv_scrape_duration_seconds` | 中 | 采集性能和 occtl 阻塞排查有用 |
| `ocserv_bytes_rx/tx_total` | 中 | 当前在线会话流量求和，不适合作为严格单调 Counter 使用 |
| `ocserv_uptime_seconds` | 中 | 服务运行时长辅助排障 |
| `ocserv_build_info` | 低中 | 版本定位有用，维护成本低 |
| `ocserv_user_bytes_rx/tx_rate_bytes_per_second` | 低中 | 当前明细诊断有价值，仅 Sessions 看板使用 |

**环境变量**：`OCSERV_SOCKET`（默认 `/var/run/occtl.socket`）、`METRICS_PORT`（默认 `9100`）、`EXPORTER_INTERVAL_SECONDS`（镜像和监控编排默认 `10`，最小 `5`）、`OCCTL_TIMEOUT_SECONDS`（镜像默认 `5`，监控编排默认 `2`）、`EXPORTER_ENABLE_SESSION_DETAIL_METRICS`（默认 `false`）。

### 7.3 Nginx 反向代理

**模板机制**：`nginx/templates/*.conf.template` 中的 `${DOMAIN}` 在容器启动时通过 `envsubst` 替换，生成 `nginx/conf.d/` 下的实际配置。

| 路径 | 目标 | 认证 |
|:--|:--|:--|
| `/grafana/` | Grafana | Grafana 登录 |
| `/prometheus/` | Prometheus | htpasswd |
| `/prometheus/api/v1/admin` | 拒绝 403 | 安全拦截 |

**安全特性**：TLS 1.2+1.3、HSTS、OCSP Stapling、WebSocket 支持（Grafana Live）。

### 7.4 CI/CD 自动构建

| 触发事件 | 生成标签 |
|:--|:--|
| push main/master | `1.4.2`、`latest` |
| push `v*` 标签 | `1.4.2` |
| PR | 仅构建测试，不推送标签 |

流程：下载源码 → QEMU + Buildx → 多架构构建 → 推送 → Trivy 安全扫描。

### 7.5 Fail2Ban 安全防护

安装在宿主机上，监控 Nginx 访问日志。

| 参数 | 值 | 说明 |
|:--|:--|:--|
| `maxretry` | 5 | 10 分钟内最大失败次数 |
| `bantime` | 3600 | 封禁 1 小时 |
| 匹配路径 | `/prometheus/` (401)、`/grafana/login` (401/403) | - |

### 7.6 Docker 安装脚本

`install-docker.sh` 特性：

- 支持 12+ Linux 发行版
- 并发探测多个镜像源，自动选最快
- 幂等执行（已安装则跳过）
- 智能配置 `daemon.json`（保留已有配置）

```bash
sudo bash install-docker.sh [-y] [--force] [--no-mirror] [--skip-cloud]
```

---

## 许可证

[GPL-2.0-or-later](https://www.gnu.org/licenses/gpl-2.0.html)
