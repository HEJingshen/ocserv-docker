# Alpine 基础镜像构建基线

## 摘要

当前默认构建使用官方 Alpine 镜像：

| 镜像 | Dockerfile | 发布标签 |
|:--|:--|:--|
| ocserv | `Dockerfile` | `kingsonho/ocserv:${OCSERV_VERSION}`；`latest` 指向该版本标签 |

本地构建默认使用 `alpine:3.23.4`。发布构建为 amd64 和 arm64 分别传入官方 Alpine 平台 digest，使基础镜像输入固定，同时让 Buildx 负责平台解析。

## 版本基线

| 项目 | 值 |
|:--|:--|
| Alpine image | `alpine:3.23.4` |
| amd64 digest | `sha256:4d889c14e7d5a73929ab00be2ef8ff22437e7cbc545931e52554a7b00e123d8b` |
| arm64 digest | `sha256:378c4c5418f7493bd500ad21ffb43818d0689daaad43e3261859fb417d1481a0` |

Dockerfile 使用 BuildKit cache mount 缓存 `apk` 索引，保留 virtual package 和 `so:` 运行时依赖解析流程，并避免把 apk 索引缓存写入最终镜像层。

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

arm64 构建使用 `--platform linux/arm64`。

## 验证清单

### 默认构建验证

- 构建 `Dockerfile`。
- 确认 `/etc/alpine-release` 输出 `3.23.4`。
- 确认 `apk --version`、`ocserv --version`、`occtl --version` 正常，并确认 `/init` 可执行。
- 确认 workflow 发布版本标签，从版本标签创建 `latest` 别名，并为多架构 manifest 保留 SBOM/provenance attestation。
