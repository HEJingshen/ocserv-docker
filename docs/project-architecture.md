# 项目架构

## 总览

本项目将 OpenConnect Server（ocserv）容器化，围绕 **主服务** 核心，向外扩展 **监控栈**、**安全防护**、**CI/CD 自动化** 三层能力。

```
┌─────────────────────────────────────────────────────┐
│                      用户客户端                       │
└──────────────────────┬──────────────────────────────┘
                       │ :443 TCP/UDP
┌──────────────────────▼──────────────────────────────┐
│                   Docker Host                       │
│                                                     │
│  ┌──────────────┐    ┌───────────────────┐          │
│  │   ocserv     │───▶│ ocserv-exporter   │          │
│  │  s6-overlay  │    │  (Unix socket)    │          │
│  └──────────────┘    └────────┬──────────┘          │
│                               │ :9100               │
│  ┌──────────────┐    ┌────────▼───────────┐         │
│  │  Prometheus  │◄───│  scrape /metrics   │         │
│  │  :9090       │    └────────┬───────────┘         │
│  └──────┬───────┘             │                     │
│         │ query               │ query               │
│  ┌──────▼─────────────────────▼───────────┐         │
│  │              Grafana                   │         │
│  │             :3000                      │         │
│  └──────────────────────┬─────────────────┘         │
│                         │ proxy                     │
│  ┌──────────────────────▼────────────────┐          │
│  │              Nginx                    │          │
│  │                :8443                  │          │
│  │  /grafana/                            │          │
│  └───────────────────────────────────────┘          │
└─────────────────────────────────────────────────────┘
```

---

## 一、镜像构建（Dockerfile）

采用官方 Alpine 多阶段构建，将 **编译** 和 **运行** 分离。发布构建按平台传入官方 Alpine digest，以固定基础镜像输入。

### 阶段一：Builder

| 项目 | 说明 |
|:--|:--|
| 基础镜像 | 官方 `alpine:3.23.4`；CI 按平台传入 digest |
| 操作 | 安装完整编译工具链（meson、ninja、gcc 等）和当前启用功能所需 Alpine 依赖 |
| 源码 | 从 `src/ocserv-${OCSERV_VERSION}.tar.xz` 本地文件解压（不联网下载） |
| 构建 | `meson setup` → `ninja` → `DESTDIR=/out ninja install`，产物输出到 `/out` |
| 变体 | `ALPINE_FLAVOR=slim|full` 控制编译能力；生产默认使用版本号标签，`latest` 作为最新版本标签别名发布 |
| apk 源 | 默认配置 `mirrors.tuna.tsinghua.edu.cn`，CI 显式使用 Alpine 官方源 |

### 阶段二：Runtime

| 项目 | 说明 |
|:--|:--|
| 基础镜像 | 与 builder 相同的官方 Alpine 基础镜像 |
| 运行依赖 | 通过 `scanelf` 解析 ocserv 二进制所需共享库，并用 `apk add --virtual .ocserv-rundeps so:*` 安装 |
| 产物复制 | `COPY --from=builder /out/ /` |
| s6-overlay | 通过 Alpine apk 仓库安装 `s6-overlay` |
| PATH | `/command` 加入 PATH，使 `docker exec` 可用 s6-overlay v3 工具 |

### Alpine 基线

`Dockerfile` 和 `exporter/Dockerfile` 均通过 `ARG ALPINE_IMAGE=alpine:3.23.4` 选择基础镜像。CI 的 amd64 和 arm64 构建分别传入官方 Alpine 平台 digest，本地开发默认使用版本标签。

| 变体 | 用途 | 关键能力 |
|:--|:--|:--|
| `full` | 默认生产标签 `kingsonho/ocserv:1.4.2`，`latest` 指向该版本标签 | PAM、GSSAPI/Kerberos，并自动探测 RADIUS、OTP/liboath |
| `slim` | 精简生产标签 `kingsonho/ocserv:1.4.2-slim`，`latest-slim` 指向该版本标签 | plain auth、occtl、LZ4、iptables NAT、s6、监控 socket |
| `exporter` | 监控采集标签 `kingsonho/ocserv-exporter:1.4.2`，`latest` 指向该版本标签 | Python exporter + `occtl` |

`slim` 禁用 utmp 编译能力，生产验证时需要用 `OCSERV_DISABLE_UTMP=true ./scripts/render-ocserv-conf.sh` 渲染配置。

### 镜像元数据（LABELs）

构建后的镜像携带 OCI 标准标注，便于运维识别：

| Label | 值 | 说明 |
|:--|:--|:--|
| `org.opencontainers.image.title` | `ocserv` | 镜像名称 |
| `org.opencontainers.image.version` | `1.4.2` | ocserv 版本 |
| `org.opencontainers.image.s6-overlay-version` | `3.2.3.0` | s6-overlay 版本 |
| `org.opencontainers.image.created` | `<BUILD_DATE>` | 构建时间 |
| `org.opencontainers.image.source` | GitHub 仓库地址 | 源码来源 |

### s6-overlay 服务定义

Dockerfile 创建 s6 服务树，并复制 `docker/ocserv/s6-init.sh` 作为 `ocserv-init` oneshot 的执行脚本：

```
/etc/s6-overlay/s6-rc.d/
├── ocserv-init/          # oneshot — 启动前检查 + iptables 配置
│   ├── up → execline 调用 /etc/ocserv/s6-init.sh
│   └── type → "oneshot"
├── ocserv/               # longrun — ocserv 主进程
│   ├── run → exec ocserv -c /etc/ocserv/ocserv.conf -f
│   ├── type → "longrun"
│   └── dependencies.d/ → 指向 ocserv-init
└── user/contents.d/      # 默认启动集合
    ├── ocserv-init → 链接
    └── ocserv → 链接
```

**依赖链**：容器启动 → s6-overlay 初始化 → `ocserv-init`（oneshot 执行配置检查 + iptables NAT/转发规则）→ 返回 0 → `ocserv`（longrun 前台运行）。

**oneshot up 文件格式**：s6-overlay v3 约定 oneshot 服务的 up 文件使用 execline 语法（`#!/command/execlineb -P`），因此初始化逻辑提取为独立 shell 脚本 `/etc/ocserv/s6-init.sh`，由 up 文件通过 execline 调用。

### 暴露端口

- `443/tcp` — TCP 连接（标准 HTTPS 端口）
- `443/udp` — UDP 连接（DTLS，AnyConnect 协议支持）

> ocserv 使用标准 443 端口，客户端无需指定端口即可连接。

### 健康检查

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ss -tln | grep -q ':443' || exit 1
```

通过 `ss` 检查 TCP 443 端口监听状态，比 `pgrep` 更可靠。ocserv 运行用户、前台模式或子进程状态变化都可能让进程名检查产生误判；而端口监听直接验证服务可用性。

---

## 二、初始化脚本（s6-init.sh）

作为 s6 `ocserv-init` oneshot 服务运行，在 ocserv 主进程启动前执行以下检查与配置：

```
1. 检查 ocserv.conf 是否存在且可读
   └─ 不存在/不可读 → exit 1，容器停止启动

2. 检查 ocserv 二进制是否存在
   └─ 不存在 → exit 1，容器停止启动

3. 创建运行时目录
   ├─ /run/ocserv   (socket 存放)
   └─ /var/log/ocserv (日志目录)

4. 解析客户端 IPv4 子网（从 ocserv.conf）
   ├─ 格式A: ipv4-network = 10.10.10.0/24       → 直接使用 CIDR
   └─ 格式B: ipv4-network = 10.10.10.0          → 配合 ipv4-netmask 计算前缀
              ipv4-netmask = 255.255.255.0

5. 配置 iptables NAT/转发规则
   ├─ FORWARD 链: 允许客户端子网双向转发
   └─ NAT POSTROUTING: MASQUERADE 伪装（出口接口自动检测）

6. 若无法解析子网，使用默认值 10.10.10.0/24
   └─ 全部通过 → exit 0，s6 继续启动 ocserv 主服务
```

**注意**：初始化逻辑维护在 `docker/ocserv/s6-init.sh`，构建时复制到镜像内的 `/etc/ocserv/s6-init.sh`。Dockerfile 只负责注册 s6 服务和设置执行权限。

这种设计确保配置错误在启动阶段就被拦截，而不是等 ocserv 崩溃后才发现问题。同时，自动配置 iptables 规则使客户端无需额外手动配置即可通过容器上网。

---

## 三、容器编排（docker-compose.yml）

主服务的核心配置：

### 环境变量管理

项目使用 `.env` 文件集中管理环境变量，通过 `${VAR:-default}` 语法实现：

- **配置文件**：`.env`（不提交）+ `.env.example`（模板，提交到 Git）
- **语法说明**：
  - `${VAR}` — 直接引用变量
  - `${VAR:-default}` — 变量未设置时使用默认值
- **加载方式**：Docker Compose 自动加载同级目录下的 `.env` 文件

**主要环境变量**：

| 变量 | 默认值 | 说明 |
|:--|:--|:--|
| `OCSERV_IMAGE` | `kingsonho/ocserv:1.4.2` | ocserv 服务镜像 |
| `OCSERV_AUTH_IMAGE` | `ocserv-auth:local` | 按需客户端证书管理工具镜像 |
| `OCSERV_PORT` | `443` | ocserv 宿主机端口 |
| `TZ` | `Asia/Shanghai` | 时区设置 |
| `LOG_MAX_SIZE` | `10m` | 日志文件最大大小 |
| `LOG_MAX_FILE` | `3` | 日志文件保留数量 |
| `NETWORK_NAME` | `monitor-net` | Docker 网络名称 |

> **安全提示**：`.env` 文件已添加到 `.gitignore`，避免敏感信息（如密码）泄露到版本控制。

### 网络与端口

| 配置项 | 值 | 作用 |
|:--|:--|:--|
| `ports` | `${OCSERV_PORT:-443}:443/tcp+udp` | 映射 ocserv 监听端口到宿主机（容器内部固定监听 443） |

> **端口映射格式**：`宿主机端口:容器端口`。容器内 ocserv 服务固定监听 443 端口（由 `ocserv.conf` 配置），仅可通过 `OCSERV_PORT` 环境变量修改宿主机映射端口。

### 配置渲染

`ocserv` 不会自动展开配置文件中的环境变量，因此项目使用 `scripts/render-ocserv-conf.sh` 在部署前渲染配置：

```
.env DOMAIN ──▶ config/ocserv.conf.template ──▶ config/ocserv.conf
```

脚本会读取 `.env`，校验 `DOMAIN`，将模板中的 `${DOMAIN}` 替换为实际域名，并生成被容器只读挂载的 `config/ocserv.conf`。这让 `DOMAIN` 同时控制证书挂载路径和 ocserv 的 `default-domain`。

### 权限与设备

| 配置项 | 值 | 作用 |
|:--|:--|:--|
| `cap_add` | `NET_ADMIN` | 允许容器操作网络栈（NAT、路由表） |
| `devices` | `/dev/net/tun` | TUN 设备，隧道连接必需 |
| `sysctls` | `net.ipv4.ip_forward=1`<br>`net.ipv6.conf.all.forwarding=1` | 启用内核 IPv4/IPv6 转发，使流量能穿过容器 |

### 卷挂载

| 宿主机路径 | 容器路径 | 模式 | 作用 |
|:--|:--|:--|:--|
| `./config/ocserv.conf` | `/etc/ocserv/ocserv.conf` | `ro`（只读） | 渲染后的主配置文件 |
| `/etc/letsencrypt/live/${DOMAIN}/fullchain.pem` | `/etc/ocserv/fullchain.pem` | `ro`（只读） | TLS 证书（公钥） |
| `/etc/letsencrypt/live/${DOMAIN}/privkey.pem` | `/etc/ocserv/privkey.pem` | `ro`（只读） | TLS 私钥 |
| `./config/auth` | `/etc/ocserv/auth` | 读写 | 用户密码目录，支持 `ocpasswd` 原子替换密码文件 |
| `./config/client-ca/public` | `/etc/ocserv/ca` | `ro`（只读） | 客户端证书 CA 与 CRL |
| `./config/config-per-user` | `/etc/ocserv/config-per-user` | `ro`（只读） | 每用户配置 |
| `./logs` | `/var/log/ocserv` | 读写 | 日志持久化 |

`ocserv-auth` 工具容器通过 `tools` profile 按需运行，额外挂载 `./config/client-ca/private` 和 `./config/user-certs` 以保存 CA 私钥、吊销记录、禁用标记和用户证书。吊销用户会写入持久禁用标记，`manage` 不会自动重发证书；恢复证书必须显式运行 `reissue`。CA 私钥不挂载到长期运行的 `ocserv` 容器。

### 日志轮转

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "10m"    # 单文件最大 10MB
    max-file: "3"      # 最多保留 3 个文件
```

防止容器 stdout 日志无限增长占满磁盘。

### 健康检查

```yaml
healthcheck:
  test: ["CMD-SHELL", "ss -tln | grep -q ':443' || exit 1"]
```

通过 `ss` 检查 TCP 443 端口是否处于监听状态，直接验证服务可用性。相比 `pgrep` 更可靠，因为 ocserv 运行用户、前台模式或子进程状态变化都可能让进程名检查产生误判。

每 30 秒执行一次，3 次失败标记为 `unhealthy`。

---

## 四、监控栈（docker-compose.monitoring.yml）

所有监控组件通过独立的 compose 文件编排，与主服务解耦，可单独启停。

### 4.1 ocserv-exporter

| 项目 | 说明 |
|:--|:--|
| 基础镜像 | 官方 `alpine:3.23.4`；CI 按平台传入 digest |
| 构建方式 | 多阶段构建，builder 从 ocserv 源码只编译 `occtl`，runtime 复制该二进制 |
| 运行方式 | 运行镜像安装 `python3` 和 `python3-prometheus-client`；镜像默认用户为 `nobody`，监控 Compose 显式设置 `user: "0:0"`，因为 Docker 部署中 `occtl` 查询 socket 需要 root peer credentials |
| 数据采集 | 通过 `occtl -j show status` 和 `occtl -j show users`（JSON 格式）调用 ocserv 的 Unix socket 接口 |
| 暴露端口 | `9100` |
| 采集周期 | 镜像和监控编排默认 10 秒；生产均衡低压配置 |
| occtl 超时 | 镜像默认 5 秒；监控编排默认 2 秒，避免采集阻塞超过 Prometheus timeout |
| 会话明细 | 默认关闭 `ocserv_user_*` 高基数指标，可通过 `EXPORTER_ENABLE_SESSION_DETAIL_METRICS=true` 开启 |

**采集指标**：

| 指标名 | 类型 | 来源 | 说明 |
|:--|:--|:--|:--|
| `ocserv_up` | Gauge | 能否成功调用 occtl | 1=在线，0=异常 |
| `ocserv_active_sessions` | Gauge | `show users` 返回列表长度 | 当前在线会话数 |
| `ocserv_active_accounts` | Gauge | `show users` 中 `Username` 去重 | 当前唯一账号数 |
| `ocserv_uptime_seconds` | Gauge | `show status.uptime` | 主进程运行时长 |
| `ocserv_start_time_seconds` | Gauge | `show status.raw_up_since` | 服务启动时间戳 |
| `ocserv_sessions_total` | Gauge | `show status.Total sessions` | 服务启动以来处理的总会话数 |
| `ocserv_authentication_failures_total` | Gauge | `show status.Total authentication failures` | 服务启动以来认证失败总数 |
| `ocserv_banned_ips` | Gauge | `show status.IPs in ban list` | 当前封禁 IP 数 |
| `ocserv_stats_*` | Gauge | `show status` stats 字段 | 上次 stats reset 以来的会话、超时、错误关闭、认证失败和流量统计 |
| `ocserv_auth_time_*_seconds` | Gauge | `show status.raw_*_auth_time` | 平均/最大认证耗时 |
| `ocserv_session_time_*_seconds` | Gauge | `show status.raw_*_session_time` | 平均/最大会话时长 |
| `ocserv_stats_bytes_rx_total` | Gauge | `show status.raw_rx` | 上次 stats reset 以来的接收字节累计值 |
| `ocserv_stats_bytes_tx_total` | Gauge | `show status.raw_tx` | 上次 stats reset 以来的发送字节累计值 |
| `ocserv_bytes_rx_total` | Gauge | 遍历用户列表累加 `RX` | 当前在线会话累计接收字节求和 |
| `ocserv_bytes_tx_total` | Gauge | 遍历用户列表累加 `TX` | 当前在线会话累计发送字节求和 |
| `ocserv_bytes_rx_rate_bytes_per_second` | Gauge | 根据相邻两次在线会话累计值差值计算 | 当前接收速率 |
| `ocserv_bytes_tx_rate_bytes_per_second` | Gauge | 根据相邻两次在线会话累计值差值计算 | 当前发送速率 |
| `ocserv_build_info` | Info | `occtl --version` | ocserv 版本 |

每会话指标默认关闭。开启后使用 `username`, `session_id`, `ip`, `vpn_ip`, `device` 标签。`session_id` 优先来自 ocserv 连接 ID，用于区分同一账号、同一公网 IP 后的多个并发连接。

采集周期：按 `EXPORTER_INTERVAL_SECONDS` 执行 `collect_metrics()`，最小 5 秒。建议小规模排障用 5 秒，均衡生产用 10 秒，资源优先或在线用户较多时用 15 秒。

### 4.2 Prometheus

| 项目 | 说明 |
|:--|:--|
| 镜像 | `prom/prometheus:v3.11.3` |
| 子路径 | `--web.route-prefix=/prometheus` 用于内部访问路径；默认不通过 Nginx 对外暴露 |
| 数据存储 | `prometheus_data` Docker 卷，容器重建不丢失 |
| 采集目标 | `ocserv:9100`，路径 `/metrics` |
| 采集间隔 | 全局 10 秒 |

### 4.3 Grafana

| 项目 | 说明 |
|:--|:--|
| 镜像 | `grafana/grafana:13.0.1-security-01` |
| 子路径 | `GF_SERVER_SERVE_FROM_SUB_PATH=true` + `GF_SERVER_ROOT_URL=https://your.domain.com:8443/grafana/` |
| 数据存储 | `grafana_data` Docker 卷 |
| 自动配置 | 通过 `monitoring/datasources/` 和 `monitoring/dashboards/` 自动注入数据源和看板 |
| 生产资源限制 | 默认限制 Grafana 为 `512m` 内存和 `1.00` CPU，可通过 `.env` 调整 |

**内置看板**：

| 看板 | 默认刷新 | 查询重点 | 说明 |
|:--|:--|:--|:--|
| Ocserv Overview | 30 秒 | 服务状态、活跃会话、活跃账号、采集健康、实时速率、累计流量、版本 | 默认长期打开，避免高基数查询 |
| Ocserv Sessions | 30 秒 | 当前会话明细、排行、连接时长 | 排障时使用，需开启 `EXPORTER_ENABLE_SESSION_DETAIL_METRICS=true` |

### 4.4 Nginx 反向代理

| 项目 | 说明 |
|:--|:--|
| 镜像 | `nginx:1.30.2-alpine3.23-slim` |
| 端口 | `${MONITORING_PORT:-8443}`（HTTPS） |
| TLS | Let's Encrypt 证书，挂载 `/etc/letsencrypt/live/${DOMAIN}` 下的证书文件 |
| 子路径路由 | `/grafana/` → Grafana |
| 配置生成 | 启动时严格校验变量/证书，通过 `envsubst` 原子渲染配置，并在 `nginx -t` 通过后启动 |

> 80 端口未映射，保留给 certbot HTTP-01 验证使用。ocserv 独立使用 `${OCSERV_PORT:-443}` 端口。

**模板化配置机制**：

Nginx 配置采用模板文件 + 启动脚本动态生成的方式，支持环境变量替换。启动脚本采用严格失败策略：`DOMAIN`、`MONITORING_PORT`、TLS 证书、模板目录或渲染结果任一异常都会阻止 Nginx 启动。

```
nginx/templates/monitoring-subpath.conf.template
                    ↓ envsubst ${DOMAIN}
nginx/conf.d/monitoring-subpath.conf（运行时生成）
```

**启动脚本**（`nginx/docker-entrypoint.sh`）：

```sh
for template in /etc/nginx/templates/*.conf.template; do
    filename=$(basename "$template" .template)
    tmp=$(mktemp "/etc/nginx/conf.d/.${filename}.XXXXXX")
    envsubst '${DOMAIN} ${MONITORING_PORT}' < "$template" > "$tmp"
    mv "$tmp" "/etc/nginx/conf.d/$filename"
done
nginx -t
```

**优势**：
- 域名配置集中在 `.env` 文件，无需手动修改多个配置文件
- 配置文件与代码分离，便于部署到不同环境
- 启动前完成配置校验，部署错误会以容器启动失败的形式尽早暴露

**关键配置**（生成后的 `nginx/conf.d/monitoring-subpath.conf`）：

- **Grafana 代理**：支持 WebSocket（Grafana Live 实时推送必需）
- **Prometheus**：保持在 Docker 网络内部，由 Grafana 数据源访问
- **安全响应头**：HSTS、X-Frame-Options、X-Content-Type-Options 等
- **SSL 参数**（`snippets/ssl-params.conf`）：TLS 1.2+1.3、ECDHE 套件、OCSP Stapling

---

## 五、Fail2Ban 防护

保护 Nginx 代理的监控端点免受暴力破解。

### 工作流程

```
Nginx access.log ──▶ Fail2Ban 过滤器 ──▶ 匹配 401/403 ──▶ 累计失败次数
                                              │
                                      ≥ 5 次 / 10 分钟
                                              │
                                              ▼
                                      nftables 封禁 IP（1 小时）
```

### 过滤器规则（`fail2ban/filter.d/nginx-auth.conf`）

**匹配**：
- `/grafana/login` 或 `/grafana/api/login` 返回 401/403

**忽略**：`/health`、`/metrics`、`/favicon`、`/static`、`/public`、`/robots.txt`、`/.well-known`

### 监狱参数（`fail2ban/jail.d/nginx-auth.conf`）

| 参数 | 值 | 说明 |
|:--|:--|:--|
| `maxretry` | 5 | 触发封禁的失败次数 |
| `findtime` | 600 | 统计窗口（10 分钟） |
| `bantime` | 3600 | 封禁时长（1 小时） |
| `action` | `nftables-multiport` | 通过 nftables 防火墙封禁 |

`scripts/setup-fail2ban.sh` 执行时会自动替换日志路径为项目的绝对路径。

---

## 六、Docker 安装脚本（install-docker.sh）

面向无 Docker 环境的一键安装脚本，支持 12+ Linux 发行版。

### 执行流程

```
1. 前置检查 → root 权限 + curl 可用性
       │
2. OS 检测 → 读取 /etc/os-release，识别发行版
       │
3. 网络检测 → curl 探测 Docker Hub 官方源延迟
       │   结果: GOOD / FAIR / SLOW / BLOCKED
       │
4. 镜像源探测 → 并发 ping/curl 测试多个源
       ├─ 包镜像源: 阿里云、腾讯云、华为云、清华
       └─ Docker 加速源: daocloud、1ms.run 等 + 保底源
       │
5. Docker 安装 → 根据 OS 类型添加官方/镜像 repo，安装 ce/cli/containerd
       │
6. daemon.json 配置 → 智能比对已有配置，仅更新 registry-mirrors
       │
7. 云厂商检测 → 并发探测元数据端点， fallback 到 DMI
```

### 设计亮点

- **幂等执行**：已安装 Docker 时跳过安装，已配置镜像源时跳过修改
- **安全配置**：使用 python3/jq 解析和写入 `daemon.json`，保留非镜像配置项
- **并发控制**：限制最大并发 job 数为 8，避免低配机器 fork 爆炸
- **set -e 安全**：避免 `((var++))` 在值为 0 时返回非零退出码
- **CI 友好**：`-y/--yes` 非交互模式，`--force` 强制重装，`--no-mirror` 跳过镜像配置

---

## 七、CI/CD（GitHub Actions）

工作流定义在 `.github/workflows/docker-build.yml`。

### 触发条件

| 事件 | 行为 |
|:--|:--|
| push 到 `main`/`master` | 构建 + 推送 |
| push `v*` 标签 | 构建 + 推送 |
| pull request | 仅构建（不推送） |

### 构建流程

```
1. Checkout 代码
       │
2. 设置 QEMU → 模拟 arm64 架构
       │
3. 设置 Buildx → 多架构构建引擎
       │
4. 下载 ocserv 源码
       │
5. 登录 Docker Hub（非 PR 时）
       │
6. 构建 + 推送
       ├─ 分平台构建: linux/amd64, linux/arm64
       ├─ 缓存: GitHub Actions 缓存（gha）
       ├─ 参数: OCSERV_VERSION, ALPINE_IMAGE, ALPINE_FLAVOR
       └─ 产物: digest-only image + SBOM/provenance attestation
       │
7. 创建 multi-arch manifest
       ├─ 先创建版本标签: kingsonho/ocserv:1.4.2, kingsonho/ocserv:1.4.2-slim, kingsonho/ocserv-exporter:1.4.2
       └─ 再从版本标签创建 latest 别名: latest, latest-slim, ocserv-exporter:latest
```

### 标签策略

| 推送场景 | 生成的标签 |
|:--|:--|
| push main/master | 先发布 `kingsonho/ocserv:1.4.2`, `kingsonho/ocserv:1.4.2-slim`, `kingsonho/ocserv-exporter:1.4.2`；再让 `latest`, `latest-slim`, `ocserv-exporter:latest` 指向对应版本标签 |
| push v* 标签 | 先发布 `kingsonho/ocserv:1.4.2`, `kingsonho/ocserv:1.4.2-slim`, `kingsonho/ocserv-exporter:1.4.2`；再让 `latest`, `latest-slim`, `ocserv-exporter:latest` 指向对应版本标签 |
| PR | 仅构建测试，不推送镜像 |

---

## 八、项目文件索引

```
├── Dockerfile                          # 多阶段构建 + s6 服务定义
├── docker-compose.yml                  # 主服务编排（支持环境变量）
├── docker-compose.monitoring.yml       # 监控栈编排（exporter + Prometheus + Grafana + Nginx）
├── install-docker.sh                   # Docker 一键安装脚本
├── docker/
│   └── ocserv/s6-init.sh               # ocserv 容器启动前初始化脚本
├── scripts/
│   ├── prepare-ocserv-config.sh        # 交互式准备 .env、目录权限并渲染 ocserv.conf
│   ├── prepare-monitoring-config.sh    # 交互式准备完整监控栈部署前配置
│   ├── render-ocserv-conf.sh           # 从 .env 渲染 ocserv.conf
│   └── setup-fail2ban.sh               # Fail2Ban 部署脚本
├── .env.example                        # 环境变量模板（提交到 Git）
├── .env                                # 实际环境变量（不提交，包含敏感配置）
│
├── src/                                # 本地构建素材（不提交到 Git）
│   └── ocserv-1.4.2.tar.xz             # ocserv 源码
│
├── config/                             # 配置文件目录
│   ├── ocserv.conf.template            # ocserv 完整配置模板
│   ├── ocserv.conf                     # 渲染后的 ocserv 主配置
│   ├── auth/ocpasswd                   # 用户密码文件
│   ├── client-ca/public/               # 客户端证书 CA 与 CRL
│   ├── client-ca/private/              # CA 私钥和吊销记录（仅工具容器挂载）
│   ├── user-certs/                     # 用户证书与 p12 文件
│   └── config-per-user/                # 每用户配置
│
├── exporter/
│   ├── Dockerfile                      # exporter Alpine 多阶段构建
│   ├── ocserv_exporter.py              # Prometheus 指标采集器模块
│   └── test_ocserv_exporter.py         # exporter 单元测试
│
├── monitoring/
│   ├── prometheus.yml                  # 采集配置（10s 间隔）
│   ├── datasources/prometheus.yml      # Grafana 数据源自动注入
│   └── dashboards/
│       ├── dashboards.yml              # Grafana dashboard provider
│       └── definitions/
│           ├── ocserv.json             # Overview 总览看板
│           └── ocserv-sessions.json    # Sessions 会话明细看板
│
├── nginx/
│   ├── templates/                      # Nginx 配置模板（支持环境变量替换）
│   │   └── monitoring-subpath.conf.template
│   ├── conf.d/                         # 生成的实际配置文件（运行时生成）
│   ├── snippets/ssl-params.conf        # TLS 安全参数
│   └── docker-entrypoint.sh            # 启动脚本（envsubst 变量替换）
│
├── fail2ban/
│   ├── filter.d/nginx-auth.conf        # 暴力破解匹配规则
│   └── jail.d/nginx-auth.conf          # 封禁参数模板
│
├── tests/
│   ├── test_fail2ban_filter.py         # Fail2Ban 样例日志匹配测试
│   └── test_nginx_entrypoint.sh        # Nginx 模板渲染和失败路径测试
│
└── .github/workflows/
    └── docker-build.yml                # CI/CD 多架构构建流水线
```
