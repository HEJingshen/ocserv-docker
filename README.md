# ocserv-docker

[![Build & Pull](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build.yml/badge.svg)](https://github.com/HEJingshen/ocserv-docker/actions/workflows/docker-build.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/kingsonho/ocserv)](https://hub.docker.com/r/kingsonho/ocserv)

OpenConnect VPN Server (ocserv) in Docker — 多架构、s6-overlay 进程监督、可选监控栈。

---

## 目录

- [前置条件](#前置条件)
- [证书配置](#证书配置)
- [部署方式](#部署方式)
- [客户端连接](#客户端连接)
- [配置参考](#配置参考)
- [故障排查](#故障排查)
- [项目结构](#项目结构)

---

## 前置条件

- Docker Engine + Compose（未安装可运行 `sudo bash install-docker.sh`）
- Linux 主机支持 TUN 设备（`/dev/net/tun` 存在）
- 域名（用于 SSL 证书申请）
- SSL/TLS 证书（推荐 Let's Encrypt，或自签名证书）

---

## 证书配置

### 方式 A：Let's Encrypt（推荐）

**前提条件**：域名已解析到服务器 IP，80 端口可访问。

```bash
# 安装 certbot
sudo apt install certbot  # Debian/Ubuntu
# sudo yum install certbot  # CentOS/RHEL

# 申请证书
sudo certbot certonly --standalone -d your.domain.com

# 证书路径
# /etc/letsencrypt/live/your.domain.com/fullchain.pem  (证书链)
# /etc/letsencrypt/live/your.domain.com/privkey.pem    (私钥)
```

**自动续期**（90 天有效期）：

```bash
# 检查是否已配置自动续期
sudo systemctl list-timers | grep certbot

# 续期后重启 VPN 服务
docker compose restart ocserv
```

### 方式 B：自签名证书（测试环境）

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout config/privkey.pem \
  -out config/fullchain.pem \
  -subj "/CN=your.domain.com"
```

> ⚠️ 自签名证书连接时需手动信任，生产环境推荐使用 Let's Encrypt。

---

## 部署方式

| 特性 | 方式一：仅 VPN | 方式二：VPN + 监控 |
|:--|:--|:--|
| 服务 | ocserv | ocserv + Prometheus + Grafana + Nginx |
| 资源 | ~50MB | ~300MB |
| 端口 | 443 | 443 + 8443 |
| 域名 | 建议 | 必需 |

### 步骤 1：克隆仓库

```bash
git clone https://github.com/HEJingshen/ocserv-docker.git
cd ocserv-docker
```

### 步骤 2：准备配置

```bash
mkdir -p config logs
cp sample.conf config/ocserv.conf
touch config/ocpasswd
```

**配置证书（选择一种）**：

```bash
# 选项 1：复制 Let's Encrypt 证书（续期后需重新复制）
sudo cp /etc/letsencrypt/live/your.domain.com/fullchain.pem config/
sudo cp /etc/letsencrypt/live/your.domain.com/privkey.pem config/
sudo chmod 644 config/fullchain.pem && sudo chmod 600 config/privkey.pem

# 选项 2：直接挂载 Let's Encrypt 证书（续期后自动生效）
# 编辑 docker-compose.yml，修改证书挂载路径：
# - /etc/letsencrypt/live/your.domain.com/fullchain.pem:/etc/ocserv/fullchain.pem:ro
# - /etc/letsencrypt/live/your.domain.com/privkey.pem:/etc/ocserv/privkey.pem:ro
```

### 步骤 3：启动服务

**方式一：仅 VPN**

```bash
docker compose up -d
```

**方式二：VPN + 监控栈**

```bash
# 配置环境变量
cp .env.example .env
# 编辑 .env：设置 DOMAIN 和 GF_ADMIN_PASSWORD

# 创建 Prometheus 认证文件
echo "admin:$(openssl passwd -apr1 'yourpassword')" > nginx/.htpasswd

# 启动
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

### 步骤 4：创建用户

```bash
docker exec -it ocserv ocpasswd -c /etc/ocserv/ocpasswd username
```

### 步骤 5：验证服务

```bash
# 检查状态
docker inspect --format='{{.State.Health.Status}}' ocserv  # 预期: healthy

# 查看日志
docker compose logs -f ocserv
```

### 常用操作命令

| 操作 | 方式一 | 方式二 |
|:--|:--|:--|
| 启动 | `docker compose up -d` | `docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d` |
| 停止 | `docker compose down` | `docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down` |
| 日志 | `docker compose logs -f` | `docker compose -f docker-compose.yml -f docker-compose.monitoring.yml logs -f` |
| 重启 | `docker compose restart` | `docker compose -f docker-compose.yml -f docker-compose.monitoring.yml restart` |
| 重载配置 | `docker exec ocserv occtl reload` | 同左 |

### 监控访问（方式二）

| 服务 | 地址 |
|:--|:--|
| Grafana | `https://your.domain.com:8443/grafana/` |
| Prometheus | `https://your.domain.com:8443/prometheus/` |

---

## 客户端连接

### 连接地址

```
https://your.domain.com
```

### 客户端下载

| 平台 | 客户端 |
|:--|:--|
| Windows/macOS | [Cisco AnyConnect](https://www.cisco.com/c/en/us/products/security/anyconnect-secure-mobility-client/) |
| macOS | OpenConnect GUI (`brew install openconnect-gui`) |
| Linux | `apt install openconnect` |
| iOS/Android | App Store / Google Play 搜索 "AnyConnect" |

### 连接步骤

1. 打开客户端，输入服务器地址 `https://your.domain.com`
2. 连接，输入用户名和密码
3. 连接成功后验证：

```bash
curl ifconfig.me  # 应显示 VPN 服务器 IP
docker exec ocserv occtl show users  # 查看当前连接用户
```

---

## 配置参考

### 核心配置项

| 配置项 | 说明 | 示例 |
|:--|:--|:--|
| `tcp-port` | TCP 端口 | `443` |
| `udp-port` | UDP 端口（DTLS） | `443` |
| `ipv4-network` | VPN IP 池 | `10.10.10.0/24` |
| `dns` | 推送 DNS | `8.8.8.8` |

完整配置参考 [sample.conf](sample.conf)。

### 卷挂载

| 宿主机路径 | 容器路径 | 说明 |
|:--|:--|:--|
| `./config/ocserv.conf` | `/etc/ocserv/ocserv.conf` | 主配置 |
| `./config/fullchain.pem` | `/etc/ocserv/fullchain.pem` | 证书 |
| `./config/privkey.pem` | `/etc/ocserv/privkey.pem` | 私钥 |
| `./config/ocpasswd` | `/etc/ocserv/ocpasswd` | 用户密码 |
| `./logs` | `/var/log/ocserv` | 日志 |

### 容器权限

| 配置 | 作用 |
|:--|:--|
| `cap_add: NET_ADMIN` | 操作网络栈 |
| `devices: /dev/net/tun` | TUN 设备 |
| `sysctls: ip_forward=1` | 内核转发 |

---

## 故障排查

### VPN 无法启动

```bash
docker compose logs ocserv  # 查看日志
ls -la config/fullchain.pem config/privkey.pem  # 检查证书
sudo ss -tlnp | grep 443  # 检查端口占用
```

**常见问题**：
- TUN 设备不存在：`sudo modprobe tun`
- 证书缺失：确保证书文件存在且路径正确

### 客户端无法连接

```bash
sudo ss -tlnp | grep 443  # TCP 端口
sudo ss -ulnp | grep 443  # UDP 端口
docker exec ocserv cat /etc/ocserv/ocpasswd  # 检查用户是否存在
```

**常见问题**：
- 防火墙：开放 TCP 443 和 UDP 443
- 域名解析：确认 DNS 指向正确 IP

### 监控面板无法访问（方式二）

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml ps  # 检查服务状态
docker compose -f docker-compose.monitoring.yml logs nginx-proxy  # 查看 Nginx 日志
```

**常见问题**：
- 检查 `.env` 中 `DOMAIN` 配置
- 确认 `nginx/.htpasswd` 文件存在

### 更多帮助

- [项目架构详解](doc/project-architecture.md)
- [监控配置指南](doc/grafana-prometheus.md)
- [Fail2Ban 防护配置](doc/fail2ban.md)

---

## 项目结构

```
.
├── docker-compose.yml              # VPN 服务
├── docker-compose.monitoring.yml   # 监控栈
├── Dockerfile                      # ocserv 镜像
├── sample.conf                    # 配置示例
├── .env.example                   # 环境变量模板
├── config/                        # 配置目录
├── logs/                          # 日志目录
├── exporter/                      # Prometheus Exporter
├── monitoring/                    # Grafana/Prometheus 配置
├── nginx/                         # Nginx 反向代理
└── fail2ban/                      # Fail2Ban 规则
```

---

## License

[GPL-2.0-or-later](https://www.gnu.org/licenses/gpl-2.0.html)