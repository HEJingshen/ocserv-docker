# Alpine Minirootfs Build Baseline

## Summary

The default build now uses explicit Alpine minirootfs for both images:

| Image | Dockerfile | Published tag |
|:--|:--|:--|
| ocserv full | `Dockerfile` | `kingsonho/ocserv:latest`, `kingsonho/ocserv:1.4.2` |
| ocserv slim | `Dockerfile` | `kingsonho/ocserv:latest-slim`, `kingsonho/ocserv:1.4.2-slim` |
| exporter | `exporter/Dockerfile` | `kingsonho/ocserv-exporter:latest`, `kingsonho/ocserv-exporter:1.4.2` |

The build uses a checked Alpine rootfs tarball instead of a floating Docker base image. Builder and runtime stages derive from the same `alpine-rootfs` stage, so package availability and runtime behavior are tied to one verified rootfs input.

## Version Baseline

| Item | Value |
|:--|:--|
| Alpine branch | `3.23` |
| Minirootfs patch | `3.23.4` |
| x86_64 tarball | `alpine-minirootfs-3.23.4-x86_64.tar.gz` |
| x86_64 sha256 | `85498865362aa7ebececa0d725a2f2e4db7ac4e4b2850b8df21645afa0d03ee3` |
| aarch64 tarball | `alpine-minirootfs-3.23.4-aarch64.tar.gz` |
| aarch64 sha256 | `9250667a8affac8f1e98086392f80f43f086626701e9bce33398eb9b6c0bd64c` |

Alpine v3.23 introduced `apk-tools v3` while preserving the v2 package and index formats. The current Dockerfiles keep the existing `apk add --no-cache`, virtual package, and `so:` runtime dependency flow. GitHub Actions has validated the minirootfs build path successfully.

## Build Flow

Download and verify a minirootfs tarball before building:

```bash
ALPINE_ARCH=x86_64 ./scripts/download-alpine-minirootfs.sh
```

Build the main full image:

```bash
docker buildx build \
  -f Dockerfile \
  --build-arg ALPINE_ARCH=x86_64 \
  --build-arg ALPINE_FLAVOR=full \
  --build-arg S6_SOURCE=apk \
  -t ocserv:latest .
```

Build the main slim image:

```bash
docker buildx build \
  -f Dockerfile \
  --build-arg ALPINE_ARCH=x86_64 \
  --build-arg ALPINE_FLAVOR=slim \
  --build-arg S6_SOURCE=apk \
  -t ocserv:latest-slim .
```

Build the exporter image:

```bash
docker buildx build \
  -f exporter/Dockerfile \
  --build-arg ALPINE_ARCH=x86_64 \
  -t ocserv-exporter:latest .
```

For arm64, use `ALPINE_ARCH=aarch64` and build with `--platform linux/arm64`.

## Validation Checklist

- Build `Dockerfile` with `ALPINE_FLAVOR=full` and `ALPINE_FLAVOR=slim`.
- Build `exporter/Dockerfile`.
- Verify `/etc/alpine-release` reports `3.23.x`.
- Verify `apk --version`, `ocserv --version`, `occtl --version`, and executable `/init`.
- Verify exporter starts and exposes `:9100/metrics`.
- Confirm workflow publishes `ocserv:latest`, `ocserv:1.4.2`, `ocserv:latest-slim`, `ocserv:1.4.2-slim`, `ocserv-exporter:latest`, and `ocserv-exporter:1.4.2`.

## Sources

- Alpine release branches: https://www.alpinelinux.org/releases/
- Alpine 3.23 release notes: https://wiki.alpinelinux.org/wiki/Release_Notes_for_Alpine_3.23.0
- Alpine minirootfs x86_64 directory: https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/
- Alpine minirootfs aarch64 directory: https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/
