#!/bin/sh
# Apply SAML2 patches to ocserv source
# Usage: apply-saml-patches.sh <ocserv-source-dir>

SRCDIR="${1:-.}"
PATCHDIR="/patches"

echo "=== Applying SAML2 patches to ocserv ==="

# Apply vpn.h patch
echo "Applying vpn.h.patch..."
patch -p1 -d "${SRCDIR}" < "${PATCHDIR}/vpn.h.patch"

# Apply common-config.h patch
echo "Applying common-config.h.patch..."
patch -p1 -d "${SRCDIR}" < "${PATCHDIR}/common-config.h.patch"

# Apply meson_options.txt patch
echo "Applying meson_options.txt.patch..."
patch -p1 -d "${SRCDIR}" < "${PATCHDIR}/meson_options.txt.patch"

# Apply meson.build patch
echo "Applying meson.build.patch..."
patch -p1 -d "${SRCDIR}" < "${PATCHDIR}/meson.build.patch"

# Apply src/meson.build patch
echo "Applying src-meson.build.patch..."
patch -p1 -d "${SRCDIR}/src" < "${PATCHDIR}/src-meson.build.patch"

# Apply config.c patch
echo "Applying config.c.patch..."
patch -p1 -d "${SRCDIR}" < "${PATCHDIR}/config.c.patch"

# Apply worker-auth.c patch
echo "Applying worker-auth.c.patch..."
patch -p1 -d "${SRCDIR}" < "${PATCHDIR}/worker-auth.c.patch"

# Copy SAML2 source files
echo "Copying SAML2 source files..."
cp "${PATCHDIR}/../saml/saml.c" "${SRCDIR}/src/auth/"
cp "${PATCHDIR}/../saml/saml.h" "${SRCDIR}/src/auth/"
cp "${PATCHDIR}/../saml/lasso_compat.h" "${SRCDIR}/src/auth/"

echo "=== SAML2 patches applied successfully ==="