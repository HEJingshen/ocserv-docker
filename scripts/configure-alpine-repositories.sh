#!/bin/sh
set -eu

APK_MIRROR="${1:-https://dl-cdn.alpinelinux.org/alpine}"

# shellcheck disable=SC1091
. /etc/os-release
ALPINE_BRANCH="${VERSION_ID}"
case "${ALPINE_BRANCH}" in
    *.*.*) ALPINE_BRANCH="${ALPINE_BRANCH%.*}" ;;
esac

printf '%s/v%s/main\n%s/v%s/community\n' \
    "${APK_MIRROR}" "${ALPINE_BRANCH}" \
    "${APK_MIRROR}" "${ALPINE_BRANCH}" \
    > /etc/apk/repositories
