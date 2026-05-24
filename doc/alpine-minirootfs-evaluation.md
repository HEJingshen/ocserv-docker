# Alpine Minirootfs Evaluation

## Summary

This repository now has two Alpine v3.23 feasibility paths:

| Path | Files | Version behavior | Intended use |
|:--|:--|:--|:--|
| Docker official image | `Dockerfile.alpine`, `exporter/Dockerfile.alpine` | `alpine:3.23` follows the latest v3.23 patch published by Docker official images | Default Alpine feasibility path |
| Explicit minirootfs | `Dockerfile.alpine-minirootfs`, `exporter/Dockerfile.alpine-minirootfs` | Fixed `alpine-minirootfs-3.23.4-{arch}.tar.gz` with sha256 verification | Supply-chain traceability and reproducibility experiment |

Docker official Alpine images are already built from Alpine minirootfs tarballs. The explicit minirootfs path therefore does not primarily reduce image size; it makes the rootfs artifact, architecture, patch version, and checksum part of the repository-controlled build inputs.

## Version Baseline

| Item | Value |
|:--|:--|
| Floating Alpine branch | `alpine:3.23` |
| Explicit minirootfs patch | `3.23.4` |
| x86_64 tarball | `alpine-minirootfs-3.23.4-x86_64.tar.gz` |
| x86_64 sha256 | `85498865362aa7ebececa0d725a2f2e4db7ac4e4b2850b8df21645afa0d03ee3` |
| aarch64 tarball | `alpine-minirootfs-3.23.4-aarch64.tar.gz` |
| aarch64 sha256 | `9250667a8affac8f1e98086392f80f43f086626701e9bce33398eb9b6c0bd64c` |

Alpine v3.23 introduced `apk-tools v3` while preserving the v2 package and index formats. The current Dockerfiles keep the existing `apk add --no-cache`, virtual package, and `so:` runtime dependency flow, so the main compatibility check is whether `scanelf` output still resolves cleanly through `apk add --virtual .ocserv-rundeps`.

## Build Flow

Download and verify a minirootfs tarball before building:

```bash
ALPINE_ARCH=x86_64 ./scripts/download-alpine-minirootfs.sh
```

Build the main minirootfs image:

```bash
docker buildx build \
  -f Dockerfile.alpine-minirootfs \
  --build-arg ALPINE_ARCH=x86_64 \
  --build-arg ALPINE_FLAVOR=slim \
  --build-arg S6_SOURCE=auto \
  -t ocserv:1.4.2-alpine-minirootfs-slim .
```

Build the exporter minirootfs image:

```bash
docker buildx build \
  -f exporter/Dockerfile.alpine-minirootfs \
  --build-arg ALPINE_ARCH=x86_64 \
  -t ocserv-exporter:1.4.2-alpine-minirootfs .
```

For arm64, use `ALPINE_ARCH=aarch64` and build with `--platform linux/arm64`.

## Comparison

| Criteria | `FROM alpine:3.23` | Explicit minirootfs |
|:--|:--|:--|
| Patch updates | Automatic within v3.23 | Manual checksum/version update |
| Multi-arch mapping | Docker official manifest handles it | CI must pass `ALPINE_ARCH` per platform |
| Source traceability | Docker image digest | Rootfs filename plus sha256 label |
| Build simplicity | Lowest | Requires pre-download step |
| Reproducibility | Depends on tag movement unless digest-pinned | Fixed patch tarball and checksum |
| Recommended default | Yes | No, keep experimental unless compliance needs it |

## Validation Checklist

- Build `Dockerfile.alpine` with `BASE_IMAGE=alpine:3.23`.
- Build `Dockerfile.alpine-minirootfs` for `linux/amd64` and `linux/arm64`.
- Build `exporter/Dockerfile.alpine` with `BASE_IMAGE=alpine:3.23`.
- Build `exporter/Dockerfile.alpine-minirootfs` for `linux/amd64` and `linux/arm64`.
- Verify `/etc/alpine-release` reports `3.23.x`.
- Verify `apk --version`, `ocserv --version`, `occtl --version`, and executable `/init`.
- Verify exporter starts and exposes `:9100/metrics`.
- Compare final image size, installed package list, image digest, and CVE scan output between both paths.

## Sources

- Alpine release branches: https://www.alpinelinux.org/releases/
- Alpine 3.23 release notes: https://wiki.alpinelinux.org/wiki/Release_Notes_for_Alpine_3.23.0
- Docker official Alpine image: https://hub.docker.com/_/alpine
- Alpine minirootfs x86_64 directory: https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/
- Alpine minirootfs aarch64 directory: https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/
