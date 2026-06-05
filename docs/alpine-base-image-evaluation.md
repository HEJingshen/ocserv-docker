# Alpine 基础镜像构建基线

## 摘要

当前默认构建使用官方 Alpine 镜像：

| 镜像 | Dockerfile | 发布标签 |
|:--|:--|:--|
| ocserv | `Dockerfile` | `kingsonho/ocserv:${OCSERV_VERSION}`；`latest` 指向该版本标签 |
| ocserv-saml | `Dockerfile.saml` | `kingsonho/ocserv:${OCSERV_VERSION}-saml`；`latest-saml` 指向该版本标签 |
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

### 默认构建（标准ocserv镜像）

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

构建证书工具镜像：

```bash
docker buildx build \
  -f auth/Dockerfile \
  -t ocserv-auth:local .
```

如果部署时要使用本地构建版本，请在 `.env` 中设置 `OCSERV_AUTH_IMAGE=ocserv-auth:local`；默认 Compose 使用 `OCSERV_VERSION` 选择 Docker Hub 上的版本标签。

### SAML构建（带SAML 2.0认证支持）

如需SAML 2.0认证支持，使用`Dockerfile.saml`构建。需要额外准备lasso源码包：

```bash
# 准备ocserv和lasso源码
OCSERV_VERSION="$(cat VERSION)"
mkdir -p src
wget -O "src/ocserv-${OCSERV_VERSION}.tar.xz" \\  "https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz"

# 下载lasso 2.9.0（包含CVE-2025-47151等安全修复）
curl -fsSL -o src/lasso-2.9.0.tar.gz \\  https://deb.debian.org/debian/pool/main/l/lasso/lasso_2.9.0.orig.tar.gz

# 构建SAML版本镜像
docker buildx build \\  --build-arg OCSERV_VERSION="${OCSERV_VERSION}" \\  -f Dockerfile.saml \\  -t "ocserv:${OCSERV_VERSION}-saml" .
```

> **安全说明**：lasso 2.9.0 包含对CVE-2025-47151（CVSS 9.8 Critical）等严重漏洞的修复。此漏洞可导致任意代码执行，建议使用最新版本。详细安全信息参见 [SAML认证文档](saml-auth.md)。

arm64 构建使用 `--platform linux/arm64`。

## 验证清单

### 默认构建验证

- 构建 `Dockerfile`。
- 构建 `auth/Dockerfile`。
- 确认 `/etc/alpine-release` 输出 `3.23.4`。
- 确认 `apk --version`、`ocserv --version`、`occtl --version` 正常，并确认 `/init` 可执行。
- 确认 `ocserv-auth` 容器内 `bash`、`certtool`、`openssl`、`flock` 可用。
- 确认 `auth` 镜像可以通过 `community` 仓库安装 `fzf`，且交互式证书撤销菜单无需降级。
- 确认 workflow 发布版本标签，从版本标签创建 `latest` 别名，并为多架构 manifest 保留 SBOM/provenance attestation。

### SAML构建验证

- 构建 `Dockerfile.saml`（需要lasso 2.9.0源码包）。
- 确认lasso库已集成：`ldd /usr/sbin/ocserv | grep lasso`。
- 确认SAML认证模块可用：检查镜像LABEL中的`auth.features`包含`SAML2.0`。