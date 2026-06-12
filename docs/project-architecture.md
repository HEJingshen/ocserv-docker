# 项目架构

## 总览

本项目将 OpenConnect Server（ocserv）容器化，围绕 **主服务** 核心，提供 **CI/CD 自动化** 能力。

```
┌─────────────────────────────────────────────────────┐
│                      用户客户端                       │
└──────────────────────┬──────────────────────────────┘
                       │ :443 TCP/UDP
┌──────────────────────▼──────────────────────────────┐
│                   Docker Host                       │
│                                                     │
│  ┌──────────────┐                                   │
│  │   ocserv     │                                   │
│  │  s6-overlay  │                                   │
│  └──────────────┘                                   │
│                                                     │
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
| 镜像 | 生产默认使用版本号标签，`latest` 作为最新版本标签别名发布 |
| apk 源 | 默认使用 Alpine 官方源（`dl-cdn.alpinelinux.org`），可通过 `APK_MIRROR` 构建参数覆盖 |

### 阶段二：Runtime

| 项目 | 说明 |
|:--|:--|
| 基础镜像 | 与 builder 相同的官方 Alpine 基础镜像 |
| 运行依赖 | 通过 `scanelf` 解析 ocserv 二进制所需共享库，并用 `apk add --virtual .ocserv-rundeps so:*` 安装 |
| 产物复制 | `COPY --from=builder /out/ /` |
| s6-overlay | 通过 Alpine apk 仓库安装 `s6-overlay` |
| PATH | `/command` 加入 PATH，使 `docker exec` 可用 s6-overlay v3 工具 |

### Alpine 基线

`Dockerfile` 通过 `ARG ALPINE_IMAGE=alpine:3.23.4` 选择基础镜像。CI 的 amd64 和 arm64 构建分别传入官方 Alpine 平台 digest，本地开发默认使用版本标签。

| 镜像 | 用途 | 关键能力 |
|:--|:--|:--|
| `ocserv` | 默认生产标签 `kingsonho/ocserv:${OCSERV_VERSION}`，`latest` 指向该版本标签 | PAM、GSSAPI/Kerberos，并自动探测 RADIUS、OTP/liboath、plain auth、occtl、LZ4、iptables NAT、s6 |

### 镜像元数据（LABELs）

构建后的镜像携带 OCI 标准标注，便于运维识别：

| Label | 值 | 说明 |
|:--|:--|:--|
| `org.opencontainers.image.title` | `ocserv` | 镜像名称 |
| `org.opencontainers.image.version` | `${OCSERV_VERSION}` | ocserv 版本，发布构建从根目录 `VERSION` 注入 |
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
| `DOMAIN` | — | **必填**。服务器域名 |
| `OCSERV_CONF_DIR` | `/etc/ocserv` | 宿主机配置目录路径 |
| `TLS_CERT_FILE` | — | **必填**。宿主机 TLS 证书链文件完整路径 |
| `TLS_KEY_FILE` | — | **必填**。宿主机 TLS 私钥文件完整路径 |
| `OCSERV_VERSION` | `1.5.0` | ocserv 镜像版本；仓库根目录 `VERSION` 是发布构建的权威来源 |
| `OCSERV_IMAGE` | `kingsonho/ocserv:${OCSERV_VERSION}` | 可选完整 ocserv 服务镜像覆盖；自定义仓库或本地镜像时使用 |
| `OCSERV_PORT` | `443` | ocserv 宿主机端口 |
| `TZ` | `Asia/Shanghai` | 时区设置 |
| `OCSERV_ENABLE_COMPRESSION` | `false` | 是否启用 ocserv 数据压缩 |
| `OCSERV_NO_UDP` | `false` | 是否禁用 UDP（DTLS）连接 |
| `OCSERV_MAX_CLIENTS` | `32` | 最大同时连接客户端数 |
| `OCSERV_MEM_LIMIT` | `512m` | 容器内存限制 |
| `OCSERV_MEMSWAP_LIMIT` | `512m` | 容器内存+Swap 限制 |
| `LOG_MAX_SIZE` | `10m` | 日志文件最大大小 |
| `LOG_MAX_FILE` | `3` | 日志文件保留数量 |
| `HEALTH_INTERVAL` | `30s` | 健康检查间隔 |
| `HEALTH_TIMEOUT` | `5s` | 健康检查超时 |
| `HEALTH_RETRIES` | `3` | 健康检查失败重试次数 |
| `HEALTH_START_PERIOD` | `15s` | 容器启动后健康检查宽限期 |

> **安全提示**：`.env` 文件已添加到 `.gitignore`，避免敏感信息（如密码）泄露到版本控制。

### 网络与端口

| 配置项 | 值 | 作用 |
|:--|:--|:--|
| `ports` | `${OCSERV_PORT:-443}:443/tcp+udp` | 映射 ocserv 监听端口到宿主机（容器内部固定监听 443） |

> **端口映射格式**：`宿主机端口:容器端口`。容器内 ocserv 服务固定监听 443 端口（由 `ocserv.conf` 配置），仅可通过 `OCSERV_PORT` 环境变量修改宿主机映射端口。

### 配置渲染

`ocserv` 不会自动展开配置文件中的环境变量，因此项目使用 `scripts/render-ocserv-conf.sh` 在部署前渲染配置：

```
.env DOMAIN ──▶ config/ocserv.conf.template ──▶ /etc/ocserv/ocserv.conf
```

脚本会读取 `.env`，校验 `DOMAIN`，将模板中的 `${DOMAIN}` 替换为实际域名，并生成到 `${OCSERV_CONF_DIR}/ocserv.conf`（被容器只读挂载）。这让 `DOMAIN` 同时控制 ocserv 的 `default-domain`。

### 权限与设备

| 配置项 | 值 | 作用 |
|:--|:--|:--|
| `cap_add` | `NET_ADMIN` | 允许容器操作网络栈（NAT、路由表） |
| `devices` | `/dev/net/tun` | TUN 设备，隧道连接必需 |
| `sysctls` | `net.ipv4.ip_forward=1`<br>`net.ipv6.conf.all.forwarding=1` | 启用内核 IPv4/IPv6 转发，使流量能穿过容器 |

### 卷挂载

| 宿主机路径 | 容器路径 | 模式 | 作用 |
|:--|:--|:--|:--|
| `${OCSERV_CONF_DIR}/ocserv.conf` | `/etc/ocserv/ocserv.conf` | `ro`（只读） | 渲染后的主配置文件 |
| `${OCSERV_CONF_DIR}/auth` | `/etc/ocserv/auth` | `rw`（读写） | 用户密码目录（ocpasswd） |
| `${TLS_CERT_FILE}` | `/etc/ocserv/fullchain.pem` | `ro`（只读） | TLS 证书（公钥） |
| `${TLS_KEY_FILE}` | `/etc/ocserv/privkey.pem` | `ro`（只读） | TLS 私钥 |
| `./logs` | `/var/log/ocserv` | 读写 | 日志持久化 |

`prepare-ocserv-config.sh` 会自动创建 `${OCSERV_CONF_DIR}` 和 `${OCSERV_CONF_DIR}/auth` 目录（需要 sudo 权限）。`scripts/occ` 封装 `occtl` 运行时控制命令，不改变容器权限、Compose 配置或挂载关系。

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

## 四、Docker 安装脚本（install-docker.sh）

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

## 五、CI/CD（GitHub Actions）

镜像构建使用 `.github/workflows/source-cache.yml` 作为唯一入口 workflow。入口 workflow 负责源码缓存准备和 artifact 扇出，然后通过 `workflow_call` 调用 `.github/workflows/ocserv.yml` reusable workflow。

### Shell 脚本风格

仓库 shell 脚本按解释器能力明确分组：

- 纯 POSIX 脚本使用 `#!/bin/sh` 和 `set -eu`，并在 CI 中通过 `sh -n` 检查；运行期入口、配置渲染脚本都归入这一类。
- 需要 Bash 特性的脚本使用 `#!/usr/bin/env bash` 和 `set -euo pipefail`，并在 CI 中通过 `bash -n` 检查；当前 `install-docker.sh` 和 `scripts/occ` 归入这一类。
- 新增 `.sh` 文件必须先选择上述一类，并同步更新静态测试中的脚本分类表。

### 触发条件

| 事件 | 行为 |
|:--|:--|
| `push` 到 `main`/`master` | `source-cache.yml` 按路径选择受影响镜像，校验 + 构建 + 推送 |
| `pull_request` 到 `main`/`master` | `source-cache.yml` 按路径选择受影响镜像，校验 + 构建（不推送、不保存源码 cache） |
| `workflow_dispatch` | 手动选择 `ocserv`；仅当当前 ref 是 `main`/`master` 时推送 |

### 构建流程

```
1. source-metadata job（source-cache.yml）
       ├─ 解析 VERSION
       └─ 生成 ocserv 源码 cache key 与 push_enabled
       │
2. prepare-sources job（source-cache.yml）
       ├─ 通过 `gh cache list` 先探测 cache key，命中时才执行 `actions/cache/restore`
       ├─ cache 未命中时下载源码包并强制 SHA256 校验
       ├─ trusted `main`/`master` 非 PR 场景保存源码 cache，单 job writer 避免并发 409
       └─ 上传本次 workflow run 内 source artifact 供 reusable workflow 复用
       │
3. validate job（reusable workflow）
       ├─ checkout
       ├─ shell 语法检查与 shellcheck
       ├─ 对应 Dockerfile 的 hadolint 检查
       └─ docker compose 配置展开校验
       │
4. build job（amd64/arm64 并行）
       ├─ matrix.platform.arch: amd64, arm64
       ├─ matrix.platform.runner: amd64 使用 `ubuntu-24.04`，arm64 使用 `ubuntu-24.04-arm`
       ├─ 下载 `prepare-sources` 生成的源码 artifact 并再次 SHA256 校验
       ├─ Buildx 单平台构建，按 workflow + arch 分 scope 复用 GHA 构建缓存
       ├─ 仅在 `main`/`master` 非 PR 场景按 digest 推送单平台镜像并上传 digest artifact
       └─ 生成 SBOM/provenance
       │
5. merge-manifests job
       ├─ 下载 amd64/arm64 digest artifacts
       ├─ 合并 `image@sha256:<digest>` 源
       └─ 发布对应镜像的多架构版本标签和 latest 标签
       │
6. concurrency 控制
       └─ 同一入口 workflow + ref 只保留最新一次运行，自动取消旧任务
```

### 标签策略

| 推送场景 | 生成的标签 |
|:--|:--|
| `push` 到 `main`/`master` | 先按 amd64/arm64 digest 推送临时单平台结果，再合并生成 `kingsonho/ocserv:<VERSION>` 和 `kingsonho/ocserv:latest` 多架构标签 |
| `workflow_dispatch` on `main`/`master` | 与 `push main/master` 相同 |
| `pull_request` 或非主分支手动执行 | 仅构建测试，不推送镜像 |

`ocserv.yml` 只作为 reusable workflow 被 `source-cache.yml` 调用，不再独立监听 `push` 或 `pull_request`。

---

## 六、项目文件索引

```
├── Dockerfile                          # 多阶段构建 + s6 服务定义
├── docker-compose.yml                  # 主服务编排（支持环境变量）
├── install-docker.sh                   # Docker 一键安装脚本
├── docker/
│   └── ocserv/s6-init.sh               # ocserv 容器启动前初始化脚本
├── scripts/
│   ├── common.sh                        # 共享工具库（fail、validate_bool、validate_fqdn）
│   ├── configure-alpine-repositories.sh # Docker 构建阶段配置 Alpine apk 源
│   ├── prepare-ocserv-config.sh        # 交互式准备 .env、目录权限并渲染 ocserv.conf
│   ├── render-ocserv-conf.sh           # 从 .env 渲染 ocserv.conf
│   └── occ                             # occtl 运行时控制短命令入口
├── .env.example                        # 环境变量模板（提交到 Git）
├── .env                                # 实际环境变量（不提交，包含敏感配置）
│
├── src/                                # 本地构建素材（不提交到 Git）
│   └── ocserv-${OCSERV_VERSION}.tar.xz # ocserv 源码
│
├── config/                             # 配置文件目录
│   ├── ocserv.conf.template            # ocserv 完整配置模板
│   └── ocserv.conf                     # 渲染后的 ocserv 主配置
│
└── .github/workflows/
    ├── source-cache.yml                # 入口流水线，负责源码缓存准备
    └── ocserv.yml                      # ocserv reusable 多架构构建流水线
```
