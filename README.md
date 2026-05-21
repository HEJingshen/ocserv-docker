# ocserv-docker

[![Build & Pull](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build.yml/badge.svg)](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/kingsonho/ocserv)](https://hub.docker.com/r/kingsonho/ocserv)
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

### 1.2 安装 Docker

```bash
sudo bash install-docker.sh -y
```

脚本自动检测发行版、选择最快镜像源、安装 Docker CE + Compose。

### 1.3 准备 SSL 证书

**方式 A：Let's Encrypt（推荐）**

```bash
sudo apt install certbot
sudo certbot certonly --standalone -d your.domain.com
```

证书路径：`/etc/letsencrypt/live/your.domain.com/fullchain.pem` 和 `privkey.pem`

**方式 B：自签名（测试）**

```bash
mkdir -p config
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout config/privkey.pem -out config/fullchain.pem \
  -subj "/CN=your.domain.com"
```

自签名证书需要自行修改 `docker-compose.yml` 文件中证书有关路径配置

### 1.4 克隆项目

```bash
git clone https://github.com/HEJingshen/ocserv-docker.git
cd ocserv-docker
```

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
vim .env
vim config/ocserv.conf.template
./scripts/render-ocserv-conf.sh
mkdir -p config/auth
touch config/auth/ocpasswd
chmod 700 config/auth
chmod 600 config/auth/ocpasswd
```

仓库已提供 `config/ocserv.conf.template` 作为完整配置模板。`DOMAIN` 从 `.env` 渲染到 `default-domain` 后生成 `config/ocserv.conf`，容器只读挂载生成后的配置。

### 2.3 启动服务

```bash
docker compose up -d
```

容器启动时 s6-overlay 自动完成：配置验证 → iptables NAT/转发规则 → 启动 ocserv。

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

连接地址：`https://your.domain.com`

| 平台 | 客户端 |
|:--|:--|
| Windows / macOS | [Cisco AnyConnect](https://www.cisco.com/c/en/us/products/security/anyconnect-secure-mobility-client/) |
| macOS | `brew install openconnect-gui` |
| Linux | `apt install openconnect` |
| iOS / Android | App Store / Google Play 搜索 "AnyConnect" |

**Linux 命令行**：`sudo openconnect -b https://your.domain.com --user=username`

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
- **Prometheus**：监控编排默认每 5 秒拉取指标
- **Grafana**：预置统一监控看板，按生产总览优先展示关键状态、实时流量和会话明细
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

### 3.4 启动完整栈

```bash
./scripts/render-ocserv-conf.sh
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

验证：

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml ps
docker exec nginx-proxy nginx -t
```

### 3.5 访问监控

| 服务 | 地址 | 认证 |
|:--|:--|:--|
| Grafana | `https://your.domain.com:8443/grafana/` | admin / `${GF_ADMIN_PASSWORD}` |
| Prometheus | `https://your.domain.com:8443/prometheus/` | htpasswd |

**内置仪表盘面板**：活跃会话数、活跃账号数、服务状态、运行时长、版本信息、流量速率（RX/TX）、每会话流量、用户排行、连接时长。

**Prometheus 常用查询**：

```
ocserv_active_sessions                     # 当前在线会话数
ocserv_active_accounts                     # 当前唯一账号数
ocserv_bytes_rx_rate_bytes_per_second      # 当前接收速率（字节/秒）
ocserv_up                                  # 服务是否在线
```

### 3.6 部署 Fail2Ban

保护监控端点免受暴力破解（10 分钟内 5 次失败 → 封禁 1 小时）：

```bash
./setup-fail2ban.sh
sudo fail2ban-client status nginx-auth      # 查看状态
sudo fail2ban-client set nginx-auth unbanip <IP>   # 手动解封
```

### 3.7 数据持久化

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
```

如需构建 arm64，还需下载 `s6-overlay-aarch64.tar.xz`。

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

**多架构构建**：

```bash
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
| `GF_DASHBOARDS_MIN_REFRESH_INTERVAL` | Grafana 看板最小刷新间隔，生产默认防止低于 15s | `15s` |
| `GF_ANALYTICS_REPORTING_ENABLED` | Grafana 匿名统计上报 | `false` |
| `GF_ANALYTICS_CHECK_FOR_UPDATES` | Grafana 版本更新检查 | `false` |
| `GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES` | Grafana 插件更新检查 | `false` |
| `GF_UNIFIED_ALERTING_EXECUTE_ALERTS` | Grafana 内置告警执行；不使用 Grafana 告警时建议关闭 | `false` |
| `GF_DATAPROXY_RESPONSE_LIMIT` | Grafana data proxy 单次响应大小限制（字节） | `10485760` |
| `GRAFANA_MEM_LIMIT` | Grafana 容器内存上限；低于 512m 时偶发 502/OOM 风险更高 | `512m` |
| `GRAFANA_MEMSWAP_LIMIT` | Grafana 容器内存+swap 上限 | `512m` |
| `GRAFANA_CPUS` | Grafana 容器 CPU 上限 | `1.00` |
| `METRICS_PORT` | 指标导出端口 | `9100` |
| `EXPORTER_INTERVAL_SECONDS` | exporter 采集间隔；少于 10 个在线用户建议 5s，10-100 人建议 10s，超过 100 人建议 15s | `5` |
| `OCCTL_TIMEOUT_SECONDS` | 单次 `occtl` 调用超时；建议小于 Prometheus `scrape_timeout` | `2` |
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
sudo ls -la /etc/letsencrypt/live/your.domain.com/fullchain.pem /etc/letsencrypt/live/your.domain.com/privkey.pem
sudo ss -tlnp | grep 443
```

| 原因 | 解决 |
|:--|:--|
| 证书缺失 | 确认证书文件存在且路径正确 |
| 配置语法错误 | 先修正 `config/ocserv.conf.template`，再运行 `./scripts/render-ocserv-conf.sh` |
| TUN 设备不存在 | `sudo modprobe tun` |
| 端口被占用 | 修改 `.env` 中 `OCSERV_PORT` |

### 6.2 客户端无法连接

```bash
docker inspect --format='{{.State.Health.Status}}' ocserv
sudo ss -tlnp | grep 443 && sudo ss -ulnp | grep 443
sudo ufw allow 443/tcp && sudo ufw allow 443/udp
```

| 原因 | 解决 |
|:--|:--|
| 防火墙阻止 | 开放 TCP/UDP 443 |
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
docker logs nginx-proxy
```

| 原因 | 解决 |
|:--|:--|
| `DOMAIN` 未配置 | 在 `.env` 中设置 |
| `MONITORING_PORT` 非法 | 设置为 `1-65535` 范围内的数字 |
| htpasswd 缺失或为空 | 运行步骤 3.3 生成非空 `nginx/.htpasswd` |
| 证书路径错误 | 确认 `SSL_CERT_DIR` 目录存在 |
| Nginx 配置生成失败 | 检查 `docker logs nginx-proxy` 中的 entrypoint 错误，并修正 `.env`、证书或模板 |

### 6.6 Exporter 采集异常

```bash
docker logs ocserv-exporter
docker exec ocserv ls -la /var/run/occtl.socket
docker exec ocserv occtl -j show status
```

| 原因 | 解决 |
|:--|:--|
| socket 不存在 | 重启 ocserv 容器 |
| 版本不匹配 | 确保 exporter 与 ocserv 版本一致 |

### 6.7 证书续期后处理

| 挂载方式 | 续期后操作 |
|:--|:--|
| 复制到 `config/` | 重新复制 + `docker compose restart ocserv` |
| 直接挂载 `/etc/letsencrypt/live/` | `docker compose restart ocserv` |

验证：`echo | openssl s_client -connect your.domain.com:443 2>/dev/null | openssl x509 -noout -dates`

---

## 七、功能模块指南

### 7.1 s6-overlay 进程管理

**启动流程**：

```
容器启动 → s6-overlay → ocserv-init (oneshot: 配置验证 + iptables) → ocserv (longrun)
```

**优势**：配置错误在启动阶段拦截，而非等 ocserv 崩溃后发现；自动配置 iptables，容器启动即可让客户端上网；进程异常自动重启。

```bash
docker exec ocserv s6-rc list          # 查看服务列表
docker exec ocserv occtl reload        # 不重启容器重载配置
```

### 7.2 Prometheus Exporter

通过 `occtl -j` JSON 输出采集指标。exporter 镜像默认每 15 秒采集一次；监控编排在生产环境默认设置为 5 秒，适合少于 10 个同时在线用户的小规模部署。

| 指标 | 类型 | 说明 |
|:--|:--|:--|
| `ocserv_up` | Gauge | 1=正常, 0=异常 |
| `ocserv_active_sessions` | Gauge | 活跃会话数 |
| `ocserv_active_accounts` | Gauge | 活跃唯一账号数 |
| `ocserv_uptime_seconds` | Gauge | 运行时长 |
| `ocserv_bytes_rx/tx_total` | Gauge | 当前活跃会话累计收发流量求和，不是严格单调 Counter |
| `ocserv_bytes_rx/tx_rate_bytes_per_second` | Gauge | 实时收发速率（字节/秒） |
| `ocserv_user_bytes_rx/tx` | Gauge | 每会话流量（带 username, session_id, ip, vpn_ip, device 标签） |
| `ocserv_user_bytes_rx/tx_rate_bytes_per_second` | Gauge | 每会话实时速率（带 username, session_id, ip, vpn_ip, device 标签） |

自动清理已断开用户的标签，防止指标泄漏。服务不可用时重置所有指标。

同一账号多设备同时连接时，`ocserv_active_sessions` 会按连接会话计数，`ocserv_active_accounts` 会按唯一账号计数。每会话指标使用 `session_id` 区分连接，即使两台设备位于同一 NAT 公网 IP 后也不会互相覆盖。

**指标重要性评估**：

| 指标 | 重要性 | 评估 |
|:--|:--|:--|
| `ocserv_up` | 关键 | 服务可用性核心指标，应保留 |
| `ocserv_active_sessions` | 关键 | 当前真实在线会话数 |
| `ocserv_active_accounts` | 高 | 区分同账号多设备场景，排障价值高 |
| `ocserv_bytes_rx/tx_rate_bytes_per_second` | 高 | 实时带宽面板核心指标 |
| `ocserv_scrape_errors_total` | 高 | 发现 exporter、occtl 或 socket 异常 |
| `ocserv_user_bytes_rx/tx` | 中高 | 每会话流量、排行、明细表依赖，标签基数随会话数增长 |
| `ocserv_user_connected_seconds` | 中高 | 连接时长排障有用 |
| `ocserv_scrape_duration_seconds` | 中 | 采集性能和 occtl 阻塞排查有用 |
| `ocserv_bytes_rx/tx_total` | 中 | 活跃会话流量求和，不适合作为严格单调 Counter 使用 |
| `ocserv_uptime_seconds` | 中 | 服务运行时长辅助排障 |
| `ocserv_build_info` | 低中 | 版本定位有用，维护成本低 |
| `ocserv_user_bytes_rx/tx_rate_bytes_per_second` | 低中 | 当前明细诊断有价值，Grafana 默认看板未直接展示 |

**环境变量**：`OCSERV_SOCKET`（默认 `/var/run/occtl.socket`）、`METRICS_PORT`（默认 `9100`）、`EXPORTER_INTERVAL_SECONDS`（镜像默认 `15`，监控编排默认 `5`，最小 `5`）、`OCCTL_TIMEOUT_SECONDS`（镜像默认 `5`，监控编排默认 `2`）。

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
