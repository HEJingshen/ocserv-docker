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

### 1.4 克隆项目

```bash
git clone https://github.com/HEJingshen/ocserv-docker.git
cd ocserv-docker
```

---

## 二、单独部署 ocserv

### 2.1 准备配置

```bash
mkdir -p config logs
cp sample.conf config/ocserv.conf
touch config/ocpasswd
```

**放置证书**（以 Let's Encrypt 为例）：

```bash
sudo cp /etc/letsencrypt/live/your.domain.com/fullchain.pem config/
sudo cp /etc/letsencrypt/live/your.domain.com/privkey.pem config/
sudo chmod 644 config/fullchain.pem && sudo chmod 600 config/privkey.pem
```

> **技巧**：直接挂载原始路径可在续期后自动生效，编辑 `docker-compose.yml` 将证书挂载改为：
> ```yaml
> - /etc/letsencrypt/live/your.domain.com/fullchain.pem:/etc/ocserv/fullchain.pem:ro
> - /etc/letsencrypt/live/your.domain.com/privkey.pem:/etc/ocserv/privkey.pem:ro
> ```

### 2.2 启动服务

```bash
docker compose up -d
```

容器启动时 s6-overlay 自动完成：配置验证 → iptables NAT/转发规则 → 启动 ocserv。

### 2.3 创建用户

```bash
docker exec -it ocserv ocpasswd -c /etc/ocserv/ocpasswd username
```

### 2.4 验证服务

```bash
docker inspect --format='{{.State.Health.Status}}' ocserv   # 预期: healthy
docker compose logs -f ocserv
docker exec ocserv occtl show users
```

### 2.5 客户端连接

连接地址：`https://your.domain.com`

| 平台 | 客户端 |
|:--|:--|
| Windows / macOS | [Cisco AnyConnect](https://www.cisco.com/c/en/us/products/security/anyconnect-secure-mobility-client/) |
| macOS | `brew install openconnect-gui` |
| Linux | `apt install openconnect` |
| iOS / Android | App Store / Google Play 搜索 "AnyConnect" |

**Linux 命令行**：`sudo openconnect -b https://your.domain.com --user=username`

### 2.6 常用命令

| 操作 | 命令 |
|:--|:--|
| 启动 | `docker compose up -d` |
| 停止 | `docker compose down` |
| 重启 | `docker compose restart` |
| 查看日志 | `docker compose logs -f ocserv` |
| 在线用户 | `docker exec ocserv occtl show users` |
| 服务状态 | `docker exec ocserv occtl show status` |
| 重载配置 | `docker exec ocserv occtl reload` |
| 删除用户 | `docker exec ocserv ocpasswd -d /etc/ocserv/ocpasswd username` |

---

## 三、与监控系统一起部署

### 3.1 架构概览

```
ocserv → exporter (Unix socket) → Prometheus (scrape) → Grafana (展示)
                                                          ↑
                                                    Nginx (HTTPS :8443)
                                                    /grafana/  /prometheus/
```

- **exporter**：通过 `occtl` 采集用户数、流量、运行时长
- **Prometheus**：每 15 秒拉取指标
- **Grafana**：预置 12 个监控面板
- **Nginx**：HTTPS 反向代理，子路径分发

### 3.2 配置环境变量

```bash
cp .env.example .env
vim .env
```

**必须修改**：

| 变量 | 说明 | 示例 |
|:--|:--|:--|
| `DOMAIN` | 服务器域名 | `vpn.example.com` |
| `GF_ADMIN_PASSWORD` | Grafana 密码 | `YourStrongPassword123!` |

### 3.3 生成认证文件

```bash
echo "admin:$(openssl passwd -apr1 'YourPrometheusPassword')" > nginx/.htpasswd
```

### 3.4 启动完整栈

```bash
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

**内置仪表盘面板**：活跃用户数、服务状态、运行时长、版本信息、流量速率（RX/TX）、每用户流量、用户排行、连接时长。

**Prometheus 常用查询**：

```
ocserv_active_users                        # 当前用户数
rate(ocserv_bytes_rx_total[1m])            # 每分钟接收流量
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

**验证**：`docker run --rm ocserv:local ocserv --version`

### 4.3 构建 Exporter 镜像

```bash
docker buildx build -f exporter/Dockerfile -t ocserv-exporter:local .
```

构建后在 `.env` 中设置 `EXPORTER_IMAGE=ocserv-exporter:local`。

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
| `auth` | 认证方式 | `plain[passwd=/etc/ocserv/ocpasswd]` |
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

完整配置见 `sample.conf`（946 行）。

### 5.2 卷挂载

| 宿主机路径 | 容器路径 | 模式 | 说明 |
|:--|:--|:--|:--|
| `./config/ocserv.conf` | `/etc/ocserv/ocserv.conf` | ro | 主配置 |
| `./config/fullchain.pem` | `/etc/ocserv/fullchain.pem` | ro | 证书 |
| `./config/privkey.pem` | `/etc/ocserv/privkey.pem` | ro | 私钥 |
| `./config/ocpasswd` | `/etc/ocserv/ocpasswd` | rw | 用户密码 |
| `./logs` | `/var/log/ocserv` | rw | 日志 |

### 5.3 容器权限

| 配置 | 作用 |
|:--|:--|
| `cap_add: NET_ADMIN` | 操作网络栈（iptables NAT） |
| `devices: /dev/net/tun` | TUN 隧道设备 |
| `sysctls: net.ipv4.ip_forward=1` | 启用 IP 转发 |

### 5.4 环境变量

完整列表见 `.env.example`，按分类：

| 分类 | 变量 |
|:--|:--|
| 基础 | `TZ` |
| 域名与端口 | `DOMAIN`、`OCSERV_PORT`、`MONITORING_PORT` |
| 镜像 | `OCSERV_IMAGE`、`EXPORTER_IMAGE`、`PROMETHEUS_IMAGE`、`GRAFANA_IMAGE`、`NGINX_IMAGE` |
| Grafana | `GF_ADMIN_PASSWORD`、`GF_ALLOW_SIGN_UP` |
| 日志 | `LOG_MAX_SIZE`、`LOG_MAX_FILE` |
| 健康检查 | `HEALTH_INTERVAL`、`HEALTH_TIMEOUT`、`HEALTH_RETRIES`、`HEALTH_START_PERIOD` |

### 5.5 最小可用配置

修改以下 3 项即可启动：

```ini
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
server-cert = /etc/ocserv/fullchain.pem
server-key = /etc/ocserv/privkey.pem
```

---

## 六、故障排查

### 6.1 服务无法启动

```bash
docker compose logs ocserv
ls -la config/fullchain.pem config/privkey.pem
sudo ss -tlnp | grep 443
```

| 原因 | 解决 |
|:--|:--|
| 证书缺失 | 确认证书文件存在且路径正确 |
| 配置语法错误 | 参考 `sample.conf` 修正 |
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

### 6.3 连接后无法上网

```bash
sysctl net.ipv4.ip_forward
docker exec ocserv iptables -t nat -L POSTROUTING -n
docker compose restart ocserv
```

| 原因 | 解决 |
|:--|:--|
| 内核转发未启用 | `sudo sysctl -w net.ipv4.ip_forward=1` |
| NAT 规则异常 | 重启容器重新初始化 iptables |

### 6.4 监控面板无法访问

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml ps
docker logs nginx-proxy
```

| 原因 | 解决 |
|:--|:--|
| `DOMAIN` 未配置 | 在 `.env` 中设置 |
| htpasswd 缺失 | 运行步骤 3.3 生成 |
| 证书路径错误 | 确认 `SSL_CERT_DIR` 目录存在 |

### 6.5 Exporter 采集异常

```bash
docker logs ocserv-exporter
docker exec ocserv ls -la /var/run/occtl.socket
docker exec ocserv occtl -j show status
```

| 原因 | 解决 |
|:--|:--|
| socket 不存在 | 重启 ocserv 容器 |
| 版本不匹配 | 确保 exporter 与 ocserv 版本一致 |

### 6.6 证书续期后处理

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

通过 `occtl -j` JSON 输出采集指标，每 15 秒一次。

| 指标 | 类型 | 说明 |
|:--|:--|:--|
| `ocserv_up` | Gauge | 1=正常, 0=异常 |
| `ocserv_active_users` | Gauge | 活跃用户数 |
| `ocserv_uptime_seconds` | Gauge | 运行时长 |
| `ocserv_bytes_rx/tx_total` | Gauge | 累计收发流量 |
| `ocserv_user_bytes_rx/tx` | Gauge | 每用户流量（带 username, ip 标签） |

自动清理已断开用户的标签，防止指标泄漏。服务不可用时重置所有指标。

**环境变量**：`OCSERV_SOCKET`（默认 `/var/run/occtl.socket`）、`METRICS_PORT`（默认 `9100`）。

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
| push main | `kingsonho/ocserv:main` |
| push `v1.4.2` 标签 | `1.4.2`、`1.4`、`latest` |
| PR #42 | `pr-42` |

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
