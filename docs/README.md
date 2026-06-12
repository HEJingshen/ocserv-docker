# ocserv-docker

[![Build Images](https://github.com/GentleKingson/ocserv-docker/actions/workflows/source-cache.yml/badge.svg)](https://github.com/GentleKingson/ocserv-docker/actions/workflows/source-cache.yml)
[![Docker Image Version](https://img.shields.io/docker/v/kingsonho/ocserv?sort=semver)](https://hub.docker.com/r/kingsonho/ocserv/tags)

基于 Docker 的 OpenConnect Server（ocserv），支持 **amd64 / arm64**，内置 **s6-overlay 进程管理**。

---

## 目录

- [一、部署前准备](#一部署前准备)
- [二、部署 ocserv](#二部署-ocserv)
- [三、自行构建镜像](#三自行构建镜像)
- [四、配置参考](#四配置参考)
  - [4.3 环境变量一览](#43-环境变量一览)
- [五、故障排查](#五故障排查)
- [六、功能模块指南](#六功能模块指南)
  - [6.4 配置脚本](#64-配置脚本)

---

## 一、部署前准备

### 1.1 环境要求

| 项目 | 要求 |
|:--|:--|
| 操作系统 | Linux（Debian / Ubuntu / CentOS / Rocky / Alma 等） |
| CPU 架构 | x86_64 或 ARM64 |
| 内核模块 | `tun`（`/dev/net/tun` 存在） |
| 内存 | 建议 ≥ 64MB |
| 端口 | `443/tcp`、`443/udp` |

### 1.2 克隆项目

```bash
git clone https://github.com/GentleKingson/ocserv-docker.git
cd ocserv-docker
```

后续命令默认都在项目根目录执行。

### 1.3 安装 Docker

宿主机未安装 Docker 时，直接执行：

```bash
sudo bash install-docker.sh
```

如果还没有克隆仓库，也可以先远程下载安装脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/GentleKingson/ocserv-docker/main/install-docker.sh -o install-docker.sh
sudo bash install-docker.sh
```

### 1.4 准备 SSL 证书

生产环境推荐使用 Let's Encrypt。申请证书前确认域名已解析到当前服务器，且 TCP 80 端口可用。

```bash
sudo apt install certbot
sudo certbot certonly --standalone -d your.domain.com
```

证书路径在 `.env` 中通过 `TLS_CERT_FILE` 和 `TLS_KEY_FILE` 配置（必填）。Let's Encrypt 用户设置为：

```text
TLS_CERT_FILE=/etc/letsencrypt/live/your.domain.com/fullchain.pem
TLS_KEY_FILE=/etc/letsencrypt/live/your.domain.com/privkey.pem
```

也支持自签名或其他 CA 签发的证书，只需将这两个变量指向对应的宿主机文件路径即可。

---

## 二、部署 ocserv

### 2.1 配置环境变量并准备配置

执行准备脚本，首次会从 `.env.example` 生成 `.env`，并自动打开编辑器：

```bash
./scripts/prepare-ocserv-config.sh
```

至少修改：

- `DOMAIN`：你的服务器域名
- `TLS_CERT_FILE`：TLS 证书链文件路径（必填）
- `TLS_KEY_FILE`：TLS 私钥文件路径（必填）
- `OCSERV_PORT`：仅在不想使用默认 `443` 时修改

脚本行为：

- 若 `.env` 不存在，从 `.env.example` 复制；若已存在，检测 `.env.example` 中新增变量并警告
- 创建 `${OCSERV_CONF_DIR}/` 和 `${OCSERV_CONF_DIR}/auth/` 目录（权限 700），创建空 `ocpasswd` 文件（权限 600）
- 使用 `${EDITOR:-vi}` 打开 `.env` 供编辑（`--no-edit` 参数可跳过编辑，适用于 CI/自动化）
- 验证 `DOMAIN` 不为占位符值
- 调用 `render-ocserv-conf.sh` 渲染配置到 `${OCSERV_CONF_DIR}/ocserv.conf`

基础部署变量以 [../.env.example](../.env.example) 为准。

启动前建议做一次快速检查：

```bash
docker compose config
source .env
sudo ls -l "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"
```

### 2.2 启动服务

```bash
docker compose up -d
```

### 2.3 创建用户

配置和密码文件存储在宿主机 `/etc/ocserv` 目录。`prepare-ocserv-config.sh` 会自动创建 `/etc/ocserv/auth/` 目录和空的 `ocpasswd` 文件。

```bash
docker exec -it -u 0 ocserv ocpasswd -c /etc/ocserv/auth/ocpasswd username
```

### 2.4 验证服务

```bash
docker inspect --format='{{.State.Health.Status}}' ocserv
docker compose logs -f ocserv
./scripts/occ status
./scripts/occ users
```

预期健康状态为 `healthy`。`./scripts/occ` 是 `occtl` 的快捷封装，也可直接使用 `docker exec ocserv occtl` 命令。

### 2.5 常用命令

| 操作 | 命令 |
|:--|:--|
| 启动 | `docker compose up -d` |
| 停止 | `docker compose down` |
| 重启 | `docker compose restart` |
| 查看日志 | `docker compose logs -f ocserv` |
| 创建用户 | `docker exec -it -u 0 ocserv ocpasswd -c /etc/ocserv/auth/ocpasswd username` |
| 删除用户 | `docker exec -it -u 0 ocserv ocpasswd -c /etc/ocserv/auth/ocpasswd -d username` |
| 在线用户 | `./scripts/occ users` 或 `docker exec ocserv occtl show users` |
| 服务状态 | `./scripts/occ status` 或 `docker exec ocserv occtl show status` |
| 重载配置 | `./scripts/occ reload` 或 `docker exec ocserv occtl reload` |

---

## 三、自行构建镜像

### 3.1 准备构建素材

构建前准备 ocserv 源码包：

```bash
OCSERV_VERSION="$(cat VERSION)"
OCSERV_TARBALL_SHA256=42ced08958b9576ab134fcb7bdc7f8df5e13214fd147855f99021fedcf0eedbe
mkdir -p src
curl -L -o "src/ocserv-${OCSERV_VERSION}.tar.xz" \
  "https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz"
echo "${OCSERV_TARBALL_SHA256}  src/ocserv-${OCSERV_VERSION}.tar.xz" | sha256sum -c -
```

### 3.2 构建 ocserv 镜像

```bash
docker buildx build \
  --build-arg OCSERV_VERSION="$(cat VERSION)" \
  -t "ocserv:$(cat VERSION)" .
```

如需多架构构建：

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg OCSERV_VERSION="$(cat VERSION)" \
  -t "registry.example.com/ocserv:$(cat VERSION)" \
  --push .
```

升级 ocserv 时先更新仓库根目录 `VERSION`，再同步 `OCSERV_TARBALL_SHA256`。更多构建和镜像实现细节见 [project-architecture.md](./project-architecture.md)。

---

## 四、配置参考

### 4.1 必须知道

- 基础部署至少要改 `DOMAIN`
- 如果改过 `.env`，需要重新执行 `./scripts/render-ocserv-conf.sh`
- `render-ocserv-conf.sh` 也支持独立运行，可通过环境变量覆盖 `.env` 中的值：

  ```bash
  sudo DOMAIN=new.example.com OCSERV_MAX_CLIENTS=64 ./scripts/render-ocserv-conf.sh
  ```

- `ocserv` 默认对外端口由 `OCSERV_PORT` 控制

### 4.2 变量与配置入口

- 基础部署变量：见 [../.env.example](../.env.example)
- Compose、配置渲染、挂载和实现原理：见 [project-architecture.md](./project-architecture.md)
- ocserv 主配置模板：见 [../config/ocserv.conf.template](../config/ocserv.conf.template)

### 4.3 环境变量一览

| 变量 | 默认值 | 说明 |
|:--|:--|:--|
| `TZ` | `Asia/Shanghai` | 容器时区 |
| `DOMAIN` | — | **必填**。服务器域名，控制 ocserv `default-domain` |
| `OCSERV_CONF_DIR` | `/etc/ocserv` | 宿主机配置目录路径 |
| `TLS_CERT_FILE` | — | **必填**。宿主机 TLS 证书链文件完整路径 |
| `TLS_KEY_FILE` | — | **必填**。宿主机 TLS 私钥文件完整路径 |
| `OCSERV_PORT` | `443` | 宿主机映射端口（容器内固定 443） |
| `OCSERV_VERSION` | `1.5.0` | 镜像版本标签；发布构建以 `VERSION` 文件为准 |
| `OCSERV_IMAGE` | `kingsonho/ocserv:${OCSERV_VERSION}` | 可选完整镜像覆盖（自定义仓库或本地构建时使用） |
| `OCSERV_ENABLE_COMPRESSION` | `false` | 是否启用 ocserv 数据压缩 |
| `OCSERV_NO_UDP` | `false` | 是否禁用 UDP（DTLS）连接 |
| `OCSERV_MAX_CLIENTS` | `32` | 最大同时连接客户端数 |
| `OCSERV_MEM_LIMIT` | `512m` | 容器内存限制 |
| `OCSERV_MEMSWAP_LIMIT` | `512m` | 容器内存+Swap 限制 |
| `LOG_MAX_SIZE` | `10m` | 容器日志单文件最大大小 |
| `LOG_MAX_FILE` | `3` | 容器日志保留文件数 |
| `HEALTH_INTERVAL` | `30s` | 健康检查间隔 |
| `HEALTH_TIMEOUT` | `5s` | 健康检查超时 |
| `HEALTH_RETRIES` | `3` | 健康检查失败重试次数 |
| `HEALTH_START_PERIOD` | `15s` | 容器启动后健康检查宽限期 |

---

## 五、故障排查

### 5.1 服务无法启动

先检查日志、证书和端口占用：

```bash
docker compose logs ocserv
docker compose config
source .env
sudo ls -l "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"
OCSERV_PORT=$(awk -F= '/^OCSERV_PORT=/{print $2}' .env)
sudo ss -tlnp | grep ":${OCSERV_PORT:-443}"
```

### 5.2 客户端无法连接

重点检查健康状态、防火墙和监听端口：

```bash
docker inspect --format='{{.State.Health.Status}}' ocserv
OCSERV_PORT=$(awk -F= '/^OCSERV_PORT=/{print $2}' .env)
sudo ss -tlnp | grep ":${OCSERV_PORT:-443}"
sudo ss -ulnp | grep ":${OCSERV_PORT:-443}"
```

### 5.3 ocserv 内存增长问题

专项分析和修复背景见 [ocserv-docker-memory-issue.md](./ocserv-docker-memory-issue.md)。

```bash
docker stats --no-stream ocserv
docker exec ocserv occtl show status
docker exec ocserv occtl show users
```

---

## 六、功能模块指南

### 6.1 s6-overlay 进程管理

负责容器启动时的检查、iptables 初始化和 ocserv 主进程托管。实现细节见 [project-architecture.md](./project-architecture.md)。

### 6.2 CI/CD 自动构建

仓库通过 GitHub Actions 构建并发布多架构镜像。发布流程说明见 [project-architecture.md](./project-architecture.md)。

### 6.3 Docker 安装脚本

`install-docker.sh` 用于快速安装 Docker 与 Compose，支持多发行版和镜像源自动选择。

### 6.4 配置脚本

| 脚本 | 用途 |
|:--|:--|
| `scripts/common.sh` | 共享工具库（`fail`、`validate_bool`、`validate_fqdn`），供其他脚本 source |
| `scripts/prepare-ocserv-config.sh` | 交互式准备 `.env`、创建目录权限、渲染配置；支持 `--no-edit` 参数 |
| `scripts/render-ocserv-conf.sh` | 从 `.env` 读取变量，将 `ocserv.conf.template` 渲染为 `/etc/ocserv/ocserv.conf` |
| `scripts/occ` | `occtl` CLI 封装，支持 `users`/`status`/`reload` 子命令 |
| `scripts/configure-alpine-repositories.sh` | Docker 构建阶段配置 Alpine apk 源（自动检测版本、生成仓库 URL） |

---

## 许可证

[GPL-2.0-or-later](https://www.gnu.org/licenses/gpl-2.0.html)
