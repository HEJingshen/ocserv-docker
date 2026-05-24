#!/bin/sh
set -eu

ALPINE_VERSION="${ALPINE_VERSION:-3.23}"
ALPINE_PATCH_VERSION="${ALPINE_PATCH_VERSION:-3.23.4}"
ALPINE_ARCH="${ALPINE_ARCH:-}"
APK_MIRROR="${APK_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
OUT_DIR="${OUT_DIR:-src}"

if [ -z "${ALPINE_ARCH}" ]; then
    echo "ERROR: ALPINE_ARCH is required; expected x86_64 or aarch64" >&2
    exit 1
fi

if [ -z "${ALPINE_MINIROOTFS_SHA256:-}" ]; then
    if [ "${ALPINE_PATCH_VERSION}" != "3.23.4" ]; then
        echo "ERROR: ALPINE_MINIROOTFS_SHA256 is required for ALPINE_PATCH_VERSION=${ALPINE_PATCH_VERSION}" >&2
        exit 1
    fi
    case "${ALPINE_ARCH}" in
        x86_64)
            ALPINE_MINIROOTFS_SHA256="85498865362aa7ebececa0d725a2f2e4db7ac4e4b2850b8df21645afa0d03ee3"
            ;;
        aarch64)
            ALPINE_MINIROOTFS_SHA256="9250667a8affac8f1e98086392f80f43f086626701e9bce33398eb9b6c0bd64c"
            ;;
        *)
            echo "ERROR: Unsupported ALPINE_ARCH=${ALPINE_ARCH}; expected x86_64 or aarch64" >&2
            exit 1
            ;;
    esac
fi

file="alpine-minirootfs-${ALPINE_PATCH_VERSION}-${ALPINE_ARCH}.tar.gz"
url="${APK_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${file}"
dest="${OUT_DIR}/${file}"
tmp="${dest}.tmp"

mkdir -p "${OUT_DIR}"

echo "Downloading ${url}"
curl -fL -o "${tmp}" "${url}"

if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "${ALPINE_MINIROOTFS_SHA256}" "${tmp}" | sha256sum -c -
else
    actual="$(shasum -a 256 "${tmp}" | awk '{print $1}')"
    if [ "${actual}" != "${ALPINE_MINIROOTFS_SHA256}" ]; then
        echo "ERROR: checksum mismatch for ${tmp}" >&2
        echo "expected: ${ALPINE_MINIROOTFS_SHA256}" >&2
        echo "actual:   ${actual}" >&2
        exit 1
    fi
fi

mv "${tmp}" "${dest}"
echo "Wrote ${dest}"
