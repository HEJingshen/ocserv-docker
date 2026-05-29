# Alpine 基础镜像构建基线

## 摘要

当前默认构建使用官方 Alpine 镜像：

| 镜像 | Dockerfile | 发布标签 |
|:--|:--|:--|
| ocserv | `Dockerfile` | `kingsonho/ocserv:${OCSERV_VERSION}`；`latest` 指向该版本标签 |
| exporter | `exporter/Dockerfile` | `kingsonho/ocserv-exporter:${OCSERV_VERSION}`；`latest` 指向该版本标签 |
| ocserv-auth | `auth/Dockerfile` | `kingsonho/ocserv-auth:${OCSERV_VERSION}`；`latest` 指向该版本标签；本地备用 `ocserv-auth:local` |

本地构建默认使用 `alpine:3.23.4`。发布构建为 amd64 和 arm64 分别传入官方 Alpine 平台 digest，使基础镜像输入固定，同时让 Buildx 负责平台解析。`auth` 镜像同样复用 Alpine 基线，并通过 `scripts/configure-alpine-repositories.sh` 启用 `main + community` 仓库以安装 `fzf`。

## 版本基线

| 项目 | 值 |
|:--|:--|
| Alpine image | `alpine:3.23.4` |
| amd64 digest | `sha256:4d889c14e7d5a73929ab00be2ef8ff22437e7cbc545931e52554a7b00e123d8b` |
| arm64 digest | `sha256:378c4c5418f7493bd500ad21ffb43818d0689daaad43e3261859fb417d1481a0` |

Dockerfile 使用 BuildKit cache mount 缓存 `apk` 索引，保留 virtual package 和 `so:` 运行时依赖解析流程，并避免把 apk 索引缓存写入最终镜像层。`auth` 镜像直接用 `apk add` 安装 `bash`、`ca-certificates`、`coreutils`、`flock`、`fzf`、`gnutls-utils` 和 `openssl`，以兼容证书管理脚本当前依赖。

## 构建流程

构建前只需要准备 ocserv 源码：

```bash
OCSERV_VERSION="$(cat VERSION)"
mkdir -p src
wget -O "src/ocserv-${OCSERV_VERSION}.tar.xz" \
  "https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz"
```

构建 ocserv 主镜像：

```bash
docker buildx build \
  --build-arg OCSERV_VERSION="$(cat VERSION)" \
  -f Dockerfile \
  -t "ocserv:$(cat VERSION)" .
```

构建 exporter 镜像：

```bash
docker buildx build \
  --build-arg OCSERV_VERSION="$(cat VERSION)" \
  -f exporter/Dockerfile \
  -t "ocserv-exporter:$(cat VERSION)" .
```

构建证书工具镜像：

```bash
docker buildx build \
  -f auth/Dockerfile \
  -t ocserv-auth:local .
```

如果部署时要使用本地构建版本，请在 `.env` 中设置 `OCSERV_AUTH_IMAGE=ocserv-auth:local`；默认 Compose 使用 `OCSERV_VERSION` 选择 Docker Hub 上的版本标签。

arm64 构建使用 `--platform linux/arm64`。

## 验证清单

- 构建 `Dockerfile`。
- 构建 `exporter/Dockerfile`。
- 构建 `auth/Dockerfile`。
- 确认 `/etc/alpine-release` 输出 `3.23.4`。
- 确认 `apk --version`、`ocserv --version`、`occtl --version` 正常，并确认 `/init` 可执行。
- 确认 `ocserv-auth` 容器内 `bash`、`certtool`、`openssl`、`flock` 可用。
- 确认 `auth` 镜像可以通过 `community` 仓库安装 `fzf`，且交互式证书撤销菜单无需降级。
- 确认 exporter 可以启动并暴露 `:9100/metrics`。
- 确认 workflow 发布版本标签，从版本标签创建 `latest` 别名，并为多架构 manifest 保留 SBOM/provenance attestation。
