# Alpine Minirootfs 构建基线

## 摘要

当前默认构建为两个镜像都显式使用 Alpine minirootfs：

| 镜像 | Dockerfile | 发布标签 |
|:--|:--|:--|
| ocserv full | `Dockerfile` | `kingsonho/ocserv:1.4.2`；`latest` 指向该版本标签 |
| ocserv slim | `Dockerfile` | `kingsonho/ocserv:1.4.2-slim`；`latest-slim` 指向该版本标签 |
| exporter | `exporter/Dockerfile` | `kingsonho/ocserv-exporter:1.4.2`；`latest` 指向该版本标签 |

构建使用已校验的 Alpine rootfs tarball，而不是浮动 Docker 基础镜像。Builder 和 runtime 阶段都从同一个 `alpine-rootfs` 阶段派生，因此包可用性和运行时行为都绑定到同一个已验证的 rootfs 输入。

## 版本基线

| 项目 | 值 |
|:--|:--|
| Alpine 分支 | `3.23` |
| Minirootfs patch | `3.23.4` |
| x86_64 tarball | `alpine-minirootfs-3.23.4-x86_64.tar.gz` |
| x86_64 sha256 | `85498865362aa7ebececa0d725a2f2e4db7ac4e4b2850b8df21645afa0d03ee3` |
| aarch64 tarball | `alpine-minirootfs-3.23.4-aarch64.tar.gz` |
| aarch64 sha256 | `9250667a8affac8f1e98086392f80f43f086626701e9bce33398eb9b6c0bd64c` |

Alpine v3.23 引入了 `apk-tools v3`，同时保留 v2 包和索引格式。当前 Dockerfile 使用 BuildKit cache mount 缓存 `apk` 索引，保留 virtual package 和 `so:` 运行时依赖解析流程，并避免把 apk 索引缓存写入最终镜像层。GitHub Actions 会验证 minirootfs 构建路径。

## 构建流程

构建前先下载并校验 minirootfs tarball：

```bash
ALPINE_ARCH=x86_64 ./scripts/download-alpine-minirootfs.sh
```

构建主镜像 full 变体：

```bash
docker buildx build \
  -f Dockerfile \
  --build-arg ALPINE_ARCH=x86_64 \
  --build-arg ALPINE_FLAVOR=full \
  --build-arg S6_SOURCE=apk \
  -t ocserv:1.4.2 .
```

构建主镜像 slim 变体：

```bash
docker buildx build \
  -f Dockerfile \
  --build-arg ALPINE_ARCH=x86_64 \
  --build-arg ALPINE_FLAVOR=slim \
  --build-arg S6_SOURCE=apk \
  -t ocserv:1.4.2-slim .
```

构建 exporter 镜像：

```bash
docker buildx build \
  -f exporter/Dockerfile \
  --build-arg ALPINE_ARCH=x86_64 \
  -t ocserv-exporter:1.4.2 .
```

arm64 构建使用 `ALPINE_ARCH=aarch64`，并配合 `--platform linux/arm64`。

## 验证清单

- 使用 `ALPINE_FLAVOR=full` 和 `ALPINE_FLAVOR=slim` 构建 `Dockerfile`。
- 构建 `exporter/Dockerfile`。
- 确认 `/etc/alpine-release` 输出 `3.23.x`。
- 确认 `apk --version`、`ocserv --version`、`occtl --version` 正常，并确认 `/init` 可执行。
- 确认 exporter 可以启动并暴露 `:9100/metrics`。
- 确认 workflow 发布版本标签，从版本标签创建 `latest` 别名，并为多架构 manifest 保留 SBOM/provenance attestation。

## 资料来源

- Alpine 发布分支：https://www.alpinelinux.org/releases/
- Alpine 3.23 发布说明：https://wiki.alpinelinux.org/wiki/Release_Notes_for_Alpine_3.23.0
- Alpine minirootfs x86_64 目录：https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/
- Alpine minirootfs aarch64 目录：https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/
