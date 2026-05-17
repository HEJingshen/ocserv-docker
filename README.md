# ocserv-docker

[![Build & Pull](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build.yml/badge.svg)](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/kingsonho/ocserv)](https://hub.docker.com/r/kingsonho/ocserv)

OpenConnect VPN Server (ocserv) in Docker — 多架构、s6-overlay 进程监督、可选监控栈。

---

## 前置条件

- Docker Engine + Compose 已安装（未安装可运行 `sudo bash install-docker.sh`）
- Linux 主机支持 TUN 设备（`/dev/net/tun` 存在）
- ocserv 配置文件 + TLS 证书

---

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/HEJingshen/ocserv-docker.git
cd ocserv-docker
```

### 2. 准备配置文件和证书

```bash
mkdir -p config logs

# 从示例配置开始修改（可选）
cp sample.conf config/ocserv.conf

# 放置你的 TLS 证书（文件名需与 docker-compose.yml 挂载路径一致）
cp your-fullchain.pem config/fullchain.pem
cp your-privkey.pem config/privkey.pem

# 创建用户密码文件（首次添加用户时自动生成，也可预先创建空文件）
touch config/ocpasswd
```

> 配置文件中需确保 `server-cert` 和 `server-key` 路径分别为 `/etc/ocserv/fullchain.pem` 和 `/etc/ocserv/privkey.pem`。

### 3. 启动服务

```bash
docker compose up -d
```

等待约 15 秒后验证健康状态：

```bash
docker inspect --format='{{.State.Health.Status}}' ocserv
# 预期输出: healthy
```

### 4. 管理用户

```bash
# 添加/修改用户密码
docker exec -it ocserv ocpasswd -c /etc/ocserv/ocpasswd username

# 删除用户
docker exec -it ocserv ocpasswd -d -c /etc/ocserv/ocpasswd username
```

修改后新用户即可登录，无需重载配置。

至此 VPN 服务已可正常使用。

---

## 常用操作

| 操作 | 命令 |
|:--|:--|
| 查看实时日志 | `docker compose logs -f ocserv` |
| 重载配置（不断连） | `docker exec ocserv occtl reload` |
| 重启服务（会断连） | `docker compose restart ocserv` |
| 检查健康状态 | `docker inspect --format='{{.State.Health.Status}}' ocserv` |
| 进入容器 Shell | `docker exec -it ocserv /bin/sh` |
| 停止服务 | `docker compose down` |

> **重载 vs 重启**：`occtl reload` 通过 SIGHUP 信号热重载配置（修改 DNS、路由等），现有连接保持不断；`docker compose restart` 完全重启容器，会中断所有 VPN 连接。修改监听端口、证书路径等 `non-reloadable` 配置项后需要重启。

---

## 配置参考

### 卷挂载

| 宿主机路径 | 容器路径 | 模式 | 说明 |
|:--|:--|:--|:--|
| `./config/ocserv.conf` | `/etc/ocserv/ocserv.conf` | `ro` | 主配置文件 |
| `./config/fullchain.pem` | `/etc/ocserv/fullchain.pem` | `ro` | TLS 证书（公钥） |
| `./config/privkey.pem` | `/etc/ocserv/privkey.pem` | `ro` | TLS 私钥 |
| `./config/ocpasswd` | `/etc/ocserv/ocpasswd` | 读写 | 用户密码文件（容器内可直接修改） |
| `./logs` | `/var/log/ocserv` | 读写 | 日志持久化 |

### 常用配置项

#### 端口配置

| 配置项 | 默认值 | Scope | 说明 |
|:--|:--|:--|:--|
| `tcp-port` | 443 | global (non-reloadable) | TCP 监听端口，用于 TLS 控制通道 |
| `udp-port` | 443 | global (non-reloadable) | UDP 监听端口，用于 DTLS 数据通道 |

- **可选范围**：1-65535，推荐使用标准端口（443）避免客户端需指定端口
- **配置示例**：
  ```conf
  tcp-port = 443
  udp-port = 443
  ```
- **注意事项**：
  - TCP 和 UDP 端口通常设为相同值，客户端在同一端口尝试 DTLS 连接
  - 修改端口后需重启容器（non-reloadable）
  - 防火墙需同时开放 TCP 和 UDP 端口

#### 网络配置

| 配置项 | 默认值 | Scope | 说明 |
|:--|:--|:--|:--|
| `default-domain` | example.com | vhost | 推送给客户端的默认搜索域名 |
| `ipv4-network` | 10.10.10.0 | vhost | VPN 客户端 IP 地址池网段 |
| `ipv4-netmask` | 255.255.255.0 | vhost | 配合 ipv4-network 使用（CIDR 格式可省略） |

- **default-domain**：
  - 支持多域名，空格分隔，需用引号包裹
  - 示例：`default-domain = "example.com corp.example.com"`
  
- **ipv4-network** 支持两种格式：
  ```conf
  # 格式一：网段 + 子网掩码
  ipv4-network = 10.10.10.0
  ipv4-netmask = 255.255.255.0
  
  # 格式二：CIDR 格式（推荐）
  ipv4-network = 192.168.1.0/24
  ```
- **注意事项**：
  - 使用私有网段，避免与现有网络冲突
  - 容器启动时自动解析子网并配置 iptables NAT 规则

#### DTLS 配置

| 配置项 | 默认值 | Scope | 说明 |
|:--|:--|:--|:--|
| `no-udp` | false | vhost / user | 是否禁用 DTLS（UDP），强制仅使用 TCP |

- **可选值**：`true`（禁用 UDP） / `false`（启用 UDP）
- **配置示例**：
  ```conf
  # 全局禁用 UDP
  no-udp = true
  
  # 用户级禁用（在 per-user 配置中）
  no-udp = true
  ```
- **使用场景**：
  - 客户端防火墙阻止 UDP 时强制 TCP 模式
  - NAT 环境下 UDP 不稳定时回退到 TCP
- **性能影响**：禁用 UDP 后 VPN 性能下降约 10-30%，延迟增加

#### 其他配置

| 配置项 | 默认值 | Scope | 说明 |
|:--|:--|:--|:--|
| `max-clients` | 0 | global | 最大并发连接数（0=无限制，约8k） |
| `dns` | 8.8.8.8 | vhost | 推送给客户端的 DNS 服务器 |
| `route` | （注释掉） | vhost | 推送路由（分割隧道），需手动启用 |

完整配置参考：[sample.conf](sample.conf)

### 容器运行时权限

| 配置项 | 值 | 作用 |
|:--|:--|:--|
| `cap_add` | `NET_ADMIN` | 操作网络栈（NAT、路由表） |
| `devices` | `/dev/net/tun` | TUN 设备，VPN 隧道必需 |
| `sysctls` | `ip_forward=1`<br>`ip6.forwarding=1` | 启用 IPv4/IPv6 内核转发 |

### iptables NAT/转发规则

容器启动时会自动从 `ocserv.conf` 读取 VPN 子网（支持 CIDR 和 netmask 两种格式），并配置 iptables 规则：

- **FORWARD 链**：允许 VPN 子网双向转发
- **NAT 伪装**：将 VPN 客户端源 IP 转换为容器出口 IP，使客户端可通过容器上网

若无法解析配置中的子网，默认使用 `10.10.10.0/24`。

---

## 可选功能

### 监控栈（Prometheus + Grafana + Nginx）

通过 Nginx 反向代理在子路径下可视化 VPN 运行指标：

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

| 服务 | 地址 | 默认认证 |
|:--|:--|:--|
| Grafana | `https://your.domain.com:8443/grafana/` | admin / admin123 |
| Prometheus | `https://your.domain.com:8443/prometheus/` | htpasswd |

> 监控服务使用 8443 端口（HTTPS），与 VPN 服务的 443 端口分离。80 端口保留给 certbot 证书续期使用。

**部署前需准备**：

- SSL 证书（Let's Encrypt 或自建）
- Nginx 域名 DNS 解析
- htpasswd 密码文件

**Exporter 配置**（通过环境变量）：

| 变量 | 默认值 | 说明 |
|:--|:--|:--|
| `OCSERV_SOCKET` | `/var/run/occtl.socket` | ocserv 控制套接字路径 |
| `METRICS_PORT` | `9100` | HTTP 指标端口 |
| `METRICS_HOST` | `0.0.0.0` | HTTP 服务绑定地址 |

**采集指标**：

| 指标 | 类型 | 说明 |
|:--|:--|:--|
| `ocserv_up` | Gauge | 服务状态（1=正常，0=异常） |
| `ocserv_active_users` | Gauge | 当前活跃用户数 |
| `ocserv_uptime_seconds` | Gauge | 运行时长 |
| `ocserv_bytes_rx_total` | Gauge | 累计接收字节 |
| `ocserv_bytes_tx_total` | Gauge | 累计发送字节 |
| `ocserv_user_bytes_rx{username,ip}` | Gauge | 用户接收字节（带标签） |
| `ocserv_user_bytes_tx{username,ip}` | Gauge | 用户发送字节（带标签） |
| `ocserv_user_connected_seconds{username,ip}` | Gauge | 用户连接时长（带标签） |

详细指南：[grafana-prometheus.md](doc/grafana-prometheus.md)

### Fail2Ban 防护

保护 Nginx 代理的监控端点免受暴力破解（10 分钟内 5 次失败封禁 1 小时）：

```bash
./setup-fail2ban.sh
sudo fail2ban-client status nginx-auth
```

> `fail2ban-client` 命令需要 root 权限，请使用 `sudo` 执行。

详细指南：[fail2ban.md](doc/fail2ban.md)

---

## 自行构建镜像

### 准备本地构建素材

将以下文件放入 `src/` 目录（已纳入 `.gitignore`，不会提交到 Git）：

| 文件 | 来源 |
|:--|:--|
| `ocserv-1.4.2.tar.xz` | [infradead.org](https://www.infradead.org/ocserv/download/) |
| `s6-overlay-noarch.tar.xz` | [s6-overlay Releases](https://github.com/just-containers/s6-overlay/releases) |
| `s6-overlay-x86_64.tar.xz` | 同上（amd64） |
| `s6-overlay-aarch64.tar.xz` | 同上（arm64） |

所有构建均基于本地文件，无需在构建过程中联网。

### 构建命令

```bash
docker build -t ocserv:local .
```

### 构建参数

| 参数 | 默认值 | 说明 |
|:--|:--|:--|
| `OCSERV_VERSION` | 1.4.2 | ocserv 源码版本（决定编译版本） |
| `S6_OVERLAY_VERSION` | 3.2.3.0 | s6-overlay 版本（仅用于镜像元数据，实际版本由 src/ 中的 tarball 决定） |
| `BASE_IMAGE` | debian:trixie-slim | 基础镜像 |

```bash
docker build --build-arg OCSERV_VERSION=1.4.2 \
             --build-arg S6_OVERLAY_VERSION=3.2.3.0 \
             -t ocserv:local .
```

构建完成后，将 `docker-compose.yml` 中镜像替换为 `ocserv:local` 即可使用。

### 构建 Exporter

Exporter 同样使用多阶段构建，从源码编译 `occtl` 工具（与主镜像共用 `src/ocserv-*.tar.xz`）：

```bash
docker build -f exporter/Dockerfile -t ocserv-exporter:local .
```

构建参数：

| 参数 | 默认值 | 说明 |
|:--|:--|:--|
| `OCSERV_VERSION` | 1.4.2 | ocserv 源码版本 |

```bash
docker build --build-arg OCSERV_VERSION=1.4.2 \
             -f exporter/Dockerfile \
             -t ocserv-exporter:local .
```

构建完成后，将 `docker-compose.monitoring.yml` 中 `ocserv-exporter` 镜像替换为 `ocserv-exporter:local`。

---

## 文档导航

| 文档 | 内容 |
|:--|:--|
| [project-architecture.md](doc/project-architecture.md) | **项目架构详解** — 镜像构建、s6 服务监督、容器编排、监控栈、Fail2Ban、CI/CD 流水线 |
| [grafana-prometheus.md](doc/grafana-prometheus.md) | 监控栈部署与使用指南 |
| [fail2ban.md](doc/fail2ban.md) | Fail2Ban 防护配置与管理 |

## 项目结构

```
.
├── docker-compose.yml              # VPN 主服务编排
├── docker-compose.monitoring.yml   # 监控栈（exporter + Prometheus + Grafana + Nginx）
├── Dockerfile                      # 多阶段构建（本地源码 + s6-overlay）
├── sample.conf                     # ocserv 完整配置参考（946 行）
├── install-docker.sh               # Docker 一键安装脚本
├── setup-fail2ban.sh               # Fail2Ban 部署脚本
├── src/                            # 本地构建素材（不提交到 Git）
│   ├── ocserv-1.4.2.tar.xz         # ocserv 源码（主镜像 & exporter 共用）
│   ├── s6-overlay-noarch.tar.xz
│   ├── s6-overlay-x86_64.tar.xz
│   └── s6-overlay-aarch64.tar.xz
├── config/                         # 用户创建：配置文件目录
│   ├── ocserv.conf                 # ocserv 主配置
│   ├── fullchain.pem               # TLS 证书（公钥）
│   ├── privkey.pem                 # TLS 私钥
│   └── ocpasswd                    # 用户密码文件
├── logs/                           # 用户创建：日志持久化目录
├── exporter/
│   ├── Dockerfile                  # exporter 多阶段构建（编译 occtl）
│   └── ocserv-exporter.py          # Prometheus 指标采集器
├── monitoring/                     # Grafana 面板 & Prometheus 配置
├── nginx/                          # 反向代理配置
└── fail2ban/                       # 暴力破解防护规则
```

## License

[GPL-2.0-or-later](https://www.gnu.org/licenses/gpl-2.0.html)（与 ocserv 上游一致）。
