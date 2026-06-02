# ocserv-docker

[![Build & Pull](https://github.com/GentleKingson/ocserv-docker/actions/workflows/docker-build.yml/badge.svg)](https://github.com/GentleKingson/ocserv-docker/actions/workflows/docker-build.yml)
[![Docker Image Version](https://img.shields.io/docker/v/kingsonho/ocserv?sort=semver)](https://hub.docker.com/r/kingsonho/ocserv/tags)

基于 Docker 的 OpenConnect Server（ocserv），支持 **amd64 / arm64**，内置 **s6-overlay 进程管理**。

---

## 目录

- [一、部署前准备](#一部署前准备)
- [二、部署 ocserv](#二部署-ocserv)
- [三、自行构建镜像](#三自行构建镜像)
- [四、配置参考](#四配置参考)
- [五、故障排查](#五故障排查)
- [六、功能模块指南](#六功能模块指南)

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

默认证书路径：

```text
/etc/letsencrypt/live/your.domain.com/fullchain.pem
/etc/letsencrypt/live/your.domain.com/privkey.pem
```

仅测试时可用自签名证书，但客户端通常会弹出证书警告。需要时可用 `docker-compose.override.yml` 覆盖证书挂载。

---

## 二、部署 ocserv

### 2.1 配置环境变量并准备配置

执行准备脚本，首次会从 `.env.example` 生成 `.env`，并自动打开编辑器：

```bash
./scripts/prepare-ocserv-config.sh
```

至少修改：

- `DOMAIN`：你的服务器域名
- `OCSERV_PORT`：仅在不想使用默认 `443` 时修改

脚本会自动创建必需目录并生成 `config/ocserv.conf`。基础部署变量以 [../.env.example](../.env.example) 为准。

启动前建议做一次快速检查：

```bash
docker compose config
DOMAIN=$(awk -F= '/^DOMAIN=/{print $2}' .env)
sudo ls -l "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
```

### 2.2 启动服务

```bash
docker compose up -d
```

### 2.3 创建用户

```bash
docker exec -it -u 0 ocserv ocpasswd -c /etc/ocserv/auth/ocpasswd username
```

也可以使用仓库内置短命令创建密码用户：

```bash
./scripts/ocu add username
```

首次使用证书工具前，建议至少先创建一个密码用户。

默认证书工具镜像默认为 `kingsonho/ocserv-auth:${OCSERV_VERSION}`，版本来自 `.env` 中的 `OCSERV_VERSION`。首次使用前可先预拉取：

```bash
docker compose --profile tools pull ocserv-auth
```

### 2.4 客户端证书认证（可选登录方式）

证书工具的完整 Compose 命令可以直接使用；如果希望命令更短，也可以使用仓库内置包装脚本：

```bash
./scripts/oca init-ca
./scripts/oca manage
./scripts/oca status
./scripts/oca revoke username
./scripts/oca reissue username
./scripts/oca menu
```

`scripts/oca` 只是在宿主机上封装 `docker compose --profile tools run --rm ocserv-auth`，不会修改容器权限、挂载或工具入口。它会自动切换到仓库根目录执行，因此也可以从其他目录用绝对路径调用。

如果想在 shell 中直接输入短命令，可以先确认本机没有同名命令：

```bash
type oca
type ocu
type occ
```

然后按当前 shell 写入别名，例如 zsh 使用 `~/.zshrc`，bash 使用 `~/.bashrc`：

```bash
alias oca='/absolute/path/to/ocserv-docker/scripts/oca'
alias ocu='/absolute/path/to/ocserv-docker/scripts/ocu'
alias occ='/absolute/path/to/ocserv-docker/scripts/occ'
```

写入后重新打开 shell，或执行 `source ~/.zshrc` / `source ~/.bashrc` 让别名生效。`oca` 负责证书管理，`ocu` 只负责 `ocpasswd` 密码用户管理，`occ` 只负责 `occtl` 运行时控制。下方仍保留完整命令，适合脚本化、排障和不想设置 alias 的场景。

启用客户端证书登录前，先初始化 CA：

```bash
docker compose --profile tools run --rm ocserv-auth init-ca
```

生成或续期全部用户证书：

```bash
docker compose --profile tools run --rm ocserv-auth manage
```

通常无需重启 `ocserv`；生成或续期的主要是客户端证书与 P12 交付物。

查看证书状态：

```bash
docker compose --profile tools run --rm ocserv-auth status
```

`status` 是只读检查，不会自动创建或修复 CA/证书文件。输出会显示用户证书的到期时间；如果颁发 CA 缺失、不可读、已过期，或证书链校验失败，对应用户会显示为 `invalid-chain`，而不是 `valid`。

吊销指定用户证书：

```bash
docker compose --profile tools run --rm ocserv-auth revoke username
```

如需立即让吊销列表生效，执行：

```bash
docker exec ocserv occtl reload
```

如果不急，也可以等待 `ocserv` 自动检测 `crl.pem` 变化。

重新签发已吊销用户证书：

```bash
docker compose --profile tools run --rm ocserv-auth reissue username
```

通常无需重启 `ocserv`；新证书会在后续客户端连接时使用。

从旧 `ocserv-auth` 迁移：

```bash
./scripts/migrate-legacy-cert-auth.sh --legacy-root /path/to/old/ocserv-auth
./scripts/migrate-legacy-cert-auth.sh --legacy-root /path/to/old/ocserv-auth --apply
./scripts/migrate-legacy-cert-auth.sh --legacy-root /path/to/old/ocserv-auth --apply --backup-dir /path/to/backup
```

默认先 dry-run，不加 `--apply` 不会修改文件。执行迁移时会自动备份当前证书相关目录，并自动开启 `OCSERV_ENABLE_CERT_AUTH=true`、重新渲染配置和执行 `ocserv-auth manage`。

用户证书与 P12 交付物变化通常不需要重启服务；CRL 变化优先使用 `occtl reload`。只有首次启用证书认证，或迁移后首次切换到 `OCSERV_ENABLE_CERT_AUTH=true` 时，才需要重建或重启 `ocserv` 以加载新的认证配置。

迁移后可用以下命令验证：

迁移会启用证书认证配置，因此需要重建或重启 `ocserv` 以加载新的认证配置：

```bash
docker compose --profile tools run --rm ocserv-auth status
docker compose up -d --force-recreate ocserv
docker inspect --format='{{.State.Health.Status}}' ocserv
```

更多证书管理细节建议结合脚本帮助和实际输出操作。

### 2.5 验证服务

```bash
docker inspect --format='{{.State.Health.Status}}' ocserv
docker compose logs -f ocserv
docker exec ocserv occtl show users
```

预期健康状态为 `healthy`。

### 2.6 常用命令

| 操作 | 命令 |
|:--|:--|
| 启动 | `docker compose up -d` |
| 停止 | `docker compose down` |
| 重启 | `docker compose restart` |
| 查看日志 | `docker compose logs -f ocserv` |
| 创建用户 | `./scripts/ocu add username` 或 `docker exec -it -u 0 ocserv ocpasswd -c /etc/ocserv/auth/ocpasswd username` |
| 删除用户 | `./scripts/ocu delete username` 或 `docker exec -it -u 0 ocserv ocpasswd -c /etc/ocserv/auth/ocpasswd -d username` |
| 在线用户 | `./scripts/occ users` 或 `docker exec ocserv occtl show users` |
| 服务状态 | `./scripts/occ status` 或 `docker exec ocserv occtl show status` |
| 重载配置 | `./scripts/occ reload` 或 `docker exec ocserv occtl reload` |

删除密码用户只会更新 `ocpasswd`，不会自动吊销客户端证书。如果已启用证书认证，并且需要让该用户的现有客户端证书失效，请继续执行：

```bash
./scripts/oca revoke username
./scripts/occ reload
```

---

## 三、自行构建镜像

### 3.1 准备构建素材

构建前至少准备 ocserv 源码包：

```bash
OCSERV_VERSION="$(cat VERSION)"
OCSERV_TARBALL_SHA256=e35d748a5244b10be3a92ad4df95a534c8280c43680eecaf3cb1b20d2a22b1a5
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

### 3.3 构建证书工具镜像（可选，本地备用）

```bash
docker buildx build -f auth/Dockerfile -t ocserv-auth:local .
```

如果要在部署时使用本地构建镜像，请把 `OCSERV_AUTH_IMAGE=ocserv-auth:local` 写入 `.env`。默认情况下，Compose 会按 `OCSERV_VERSION` 拉取 Docker Hub 上的版本标签。升级 ocserv 时先更新仓库根目录 `VERSION`，再同步 `OCSERV_TARBALL_SHA256`。更多构建和镜像实现细节见 [project-architecture.md](./project-architecture.md)。

---

## 四、配置参考

### 4.1 必须知道

- 基础部署至少要改 `DOMAIN`
- 如果改过 `.env`，需要重新执行 `./scripts/render-ocserv-conf.sh`
- `ocserv` 默认对外端口由 `OCSERV_PORT` 控制

### 4.2 变量与配置入口

- 基础部署变量：见 [../.env.example](../.env.example)
- Compose、配置渲染、挂载和实现原理：见 [project-architecture.md](./project-architecture.md)
- ocserv 主配置模板：见 [../config/ocserv.conf.template](../config/ocserv.conf.template)

---

## 五、故障排查

### 5.1 服务无法启动

先检查日志、证书和端口占用：

```bash
docker compose logs ocserv
docker compose config
DOMAIN=$(awk -F= '/^DOMAIN=/{print $2}' .env)
sudo ls -l "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
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

---

## 许可证

[GPL-2.0-or-later](https://www.gnu.org/licenses/gpl-2.0.html)
