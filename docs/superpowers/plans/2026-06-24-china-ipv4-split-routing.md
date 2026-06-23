# China IPv4 Split Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add manual China IPv4 split-routing support for ocserv while keeping route-list downloads explicit and config rendering offline.

**Architecture:** Add one networking script, `scripts/update-china-ip-list.sh`, for manual HTTPS downloads and route-list validation. Extend `scripts/render-ocserv-conf.sh` so it reads only local files, converts IPv4 CIDR entries into ocserv dotted-netmask route entries, and writes the final config only after all validations pass.

**Tech Stack:** POSIX `sh`, `awk`, `grep`, `curl` or `wget`, Docker-style `.env` parsing through `scripts/common.sh`, Git.

---

## File Structure

- Create: `scripts/update-china-ip-list.sh`
  - Manual download entry point.
  - Reads `OCSERV_CHINA_IP_URL` and `OCSERV_CHINA_IP_FILE` from the environment or `.env`.
  - Requires HTTPS.
  - Validates, deduplicates, and atomically writes the local China IPv4 list.
- Modify: `scripts/render-ocserv-conf.sh`
  - Keeps existing DOMAIN, TLS, compression, UDP, and max-client rendering.
  - Adds offline route-list validation and route block generation.
  - Replaces exactly one `# @OCSERV_CHINA_IPV4_ROUTES@` marker.
- Modify: `config/ocserv.conf.template`
  - Adds the single route marker after the existing `no-route` example.
- Modify: `.env.example`
  - Documents four new `OCSERV_CHINA_*` variables with disabled-by-default behavior.
- Modify: `.gitignore`
  - Ignores downloaded `config/ip-lists/*.txt` data files.

## Task 1: Add Configuration Surface and Template Marker

**Files:**
- Modify: `.env.example`
- Modify: `.gitignore`
- Modify: `config/ocserv.conf.template`

- [ ] **Step 1: Run baseline checks that should fail before edits**

Run:

```sh
grep -Fqx 'OCSERV_CHINA_ROUTES_ENABLED=false' .env.example
```

Expected: command exits non-zero because the variable is not present yet.

Run:

```sh
grep -Fxc '# @OCSERV_CHINA_IPV4_ROUTES@' config/ocserv.conf.template
```

Expected output:

```text
0
```

Run:

```sh
git check-ignore -q -- config/ip-lists/china.txt
```

Expected: command exits non-zero because the file is not ignored yet.

- [ ] **Step 2: Add `.env.example` variables**

Apply this patch:

```diff
diff --git a/.env.example b/.env.example
--- a/.env.example
+++ b/.env.example
@@
 OCSERV_ENABLE_COMPRESSION=false
 OCSERV_NO_UDP=false
 OCSERV_MAX_CLIENTS=32
+
+# China IPv4 split routing
+# false: do not generate China IPv4 routes.
+# true: generate routes from OCSERV_CHINA_IP_FILE using OCSERV_CHINA_ROUTES_MODE.
+OCSERV_CHINA_ROUTES_ENABLED=false
+
+# route: route only China IPv4 prefixes through the VPN.
+# no-route: route all traffic through the VPN except China IPv4 prefixes.
+OCSERV_CHINA_ROUTES_MODE=route
+
+# Local China IPv4 CIDR list used by scripts/render-ocserv-conf.sh.
+# Relative paths are resolved from the repository root.
+OCSERV_CHINA_IP_FILE=config/ip-lists/china.txt
+
+# HTTPS source used only by scripts/update-china-ip-list.sh.
+OCSERV_CHINA_IP_URL=https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt
 OCSERV_MEM_LIMIT=512m
 OCSERV_MEMSWAP_LIMIT=512m
 LOG_MAX_SIZE=10m
```

- [ ] **Step 3: Ignore downloaded China route lists**

Apply this patch:

```diff
diff --git a/.gitignore b/.gitignore
--- a/.gitignore
+++ b/.gitignore
@@
 # Runtime data
 logs/
+
+# Generated China IPv4 route list
+config/ip-lists/*.txt
 
 # Python cache
 __pycache__/
```

- [ ] **Step 4: Add the unique route marker to the ocserv template**

Apply this patch:

```diff
diff --git a/config/ocserv.conf.template b/config/ocserv.conf.template
--- a/config/ocserv.conf.template
+++ b/config/ocserv.conf.template
@@
 # [scope: vhost user]
 #no-route = 192.168.5.0/255.255.255.0
+
+# This marker is replaced by scripts/render-ocserv-conf.sh.
+# Do not remove or duplicate this marker.
+# @OCSERV_CHINA_IPV4_ROUTES@
 
 # Whether to disable DTLS (UDP) for client connections. If set to true,
 # the server will only accept TCP connections and will not negotiate DTLS.
```

- [ ] **Step 5: Verify Task 1 changes**

Run:

```sh
grep -Fqx 'OCSERV_CHINA_ROUTES_ENABLED=false' .env.example
grep -Fqx 'OCSERV_CHINA_ROUTES_MODE=route' .env.example
grep -Fqx 'OCSERV_CHINA_IP_FILE=config/ip-lists/china.txt' .env.example
grep -Fqx 'OCSERV_CHINA_IP_URL=https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt' .env.example
test "$(grep -Fxc '# @OCSERV_CHINA_IPV4_ROUTES@' config/ocserv.conf.template)" -eq 1
git check-ignore -q -- config/ip-lists/china.txt
```

Expected: all commands exit zero.

- [ ] **Step 6: Commit Task 1**

Run:

```sh
git add .env.example .gitignore config/ocserv.conf.template
git commit -m "feat: add China IPv4 route config surface"
```

Expected: commit succeeds.

## Task 2: Add Manual China IPv4 Download Script

**Files:**
- Create: `scripts/update-china-ip-list.sh`

- [ ] **Step 1: Run baseline check that should fail before creating the script**

Run:

```sh
test -f scripts/update-china-ip-list.sh
```

Expected: command exits non-zero because the script does not exist yet.

- [ ] **Step 2: Create `scripts/update-china-ip-list.sh`**

Apply this patch:

```diff
diff --git a/scripts/update-china-ip-list.sh b/scripts/update-china-ip-list.sh
new file mode 100755
--- /dev/null
+++ b/scripts/update-china-ip-list.sh
@@
+#!/bin/sh
+set -eu
+
+SCRIPT_DIR=$(
+    unset CDPATH
+    cd -- "$(dirname -- "$0")" && pwd
+)
+
+# shellcheck source=scripts/common.sh disable=SC1091
+. "${SCRIPT_DIR}/common.sh"
+
+ENV_FILE=${ENV_FILE:-"${PROJECT_ROOT}/.env"}
+
+DEFAULT_URL='https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt'
+DEFAULT_OUTPUT='config/ip-lists/china.txt'
+
+ENV_URL=
+ENV_OUTPUT=
+
+if [ -f "${ENV_FILE}" ]; then
+    ENV_URL=$(env_file_value "${ENV_FILE}" OCSERV_CHINA_IP_URL)
+    ENV_OUTPUT=$(env_file_value "${ENV_FILE}" OCSERV_CHINA_IP_FILE)
+fi
+
+SOURCE_URL=${OCSERV_CHINA_IP_URL:-${ENV_URL:-${DEFAULT_URL}}}
+OUTPUT_FILE=${OCSERV_CHINA_IP_FILE:-${ENV_OUTPUT:-${DEFAULT_OUTPUT}}}
+
+case "${SOURCE_URL}" in
+    https://*)
+        ;;
+    *)
+        fail "OCSERV_CHINA_IP_URL must use HTTPS: ${SOURCE_URL}"
+        ;;
+esac
+
+case "${OUTPUT_FILE}" in
+    /*)
+        ;;
+    *)
+        OUTPUT_FILE="${PROJECT_ROOT}/${OUTPUT_FILE}"
+        ;;
+esac
+
+OUTPUT_DIR=$(dirname -- "${OUTPUT_FILE}")
+
+mkdir -p "${OUTPUT_DIR}" \
+    || fail "cannot create output directory: ${OUTPUT_DIR}"
+
+RAW_FILE=
+VALIDATED_FILE=
+
+cleanup() {
+    [ -z "${RAW_FILE:-}" ] || rm -f "${RAW_FILE}"
+    [ -z "${VALIDATED_FILE:-}" ] || rm -f "${VALIDATED_FILE}"
+}
+
+trap cleanup EXIT HUP INT TERM
+
+RAW_FILE=$(mktemp "${OUTPUT_DIR}/.china-ip.raw.XXXXXX") \
+    || fail "cannot create temporary download file"
+
+VALIDATED_FILE=$(mktemp "${OUTPUT_DIR}/.china-ip.valid.XXXXXX") \
+    || fail "cannot create temporary validation file"
+
+if command -v curl >/dev/null 2>&1; then
+    curl \
+        --fail \
+        --silent \
+        --show-error \
+        --location \
+        --retry 3 \
+        --connect-timeout 10 \
+        --max-time 120 \
+        --output "${RAW_FILE}" \
+        "${SOURCE_URL}"
+elif command -v wget >/dev/null 2>&1; then
+    wget \
+        --quiet \
+        --timeout=120 \
+        --tries=3 \
+        --output-document="${RAW_FILE}" \
+        "${SOURCE_URL}"
+else
+    fail "curl or wget is required"
+fi
+
+if ! awk '
+    function valid_cidr(value, parts, octets, count, i, prefix) {
+        count = split(value, parts, "/")
+
+        if (count != 2 || parts[2] !~ /^[0-9]+$/) {
+            return 0
+        }
+
+        prefix = parts[2] + 0
+
+        if (prefix < 1 || prefix > 32) {
+            return 0
+        }
+
+        count = split(parts[1], octets, ".")
+
+        if (count != 4) {
+            return 0
+        }
+
+        for (i = 1; i <= 4; i++) {
+            if (octets[i] !~ /^[0-9]+$/) {
+                return 0
+            }
+
+            if (octets[i] + 0 < 0 || octets[i] + 0 > 255) {
+                return 0
+            }
+        }
+
+        return 1
+    }
+
+    {
+        line = $0
+
+        sub(/\r$/, "", line)
+        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
+
+        if (line == "" || substr(line, 1, 1) == "#") {
+            next
+        }
+
+        if (!valid_cidr(line)) {
+            printf \
+                "invalid IPv4 CIDR at source line %d: %s\n", \
+                NR, line > "/dev/stderr"
+            invalid = 1
+            next
+        }
+
+        if (!seen[line]++) {
+            print line
+        }
+    }
+
+    END {
+        if (invalid) {
+            exit 1
+        }
+    }
+' "${RAW_FILE}" > "${VALIDATED_FILE}"; then
+    fail "downloaded file contains invalid IPv4 CIDR entries"
+fi
+
+PREFIX_COUNT=$(wc -l < "${VALIDATED_FILE}" | tr -d ' ')
+
+[ "${PREFIX_COUNT}" -ge 1000 ] \
+    || fail "unexpected China IPv4 prefix count: ${PREFIX_COUNT}"
+
+[ "${PREFIX_COUNT}" -le 20000 ] \
+    || fail "unexpected China IPv4 prefix count: ${PREFIX_COUNT}"
+
+chmod 0644 "${VALIDATED_FILE}"
+
+mv "${VALIDATED_FILE}" "${OUTPUT_FILE}"
+VALIDATED_FILE=
+
+printf 'Saved %s validated China IPv4 prefixes to %s\n' \
+    "${PREFIX_COUNT}" \
+    "${OUTPUT_FILE}"
+
+cleanup
+trap - EXIT HUP INT TERM
```

- [ ] **Step 3: Ensure the script is executable**

Run:

```sh
chmod +x scripts/update-china-ip-list.sh
```

Expected: command exits zero.

- [ ] **Step 4: Verify syntax and HTTPS enforcement**

Run:

```sh
sh -n scripts/update-china-ip-list.sh
OCSERV_CHINA_IP_URL=http://example.com/china.txt scripts/update-china-ip-list.sh
```

Expected: first command exits zero. Second command exits non-zero and prints:

```text
ERROR: OCSERV_CHINA_IP_URL must use HTTPS: http://example.com/china.txt
```

- [ ] **Step 5: Verify network download and Git ignore behavior**

Run:

```sh
scripts/update-china-ip-list.sh
test -s config/ip-lists/china.txt
git status --short --ignored config/ip-lists/china.txt
git check-ignore -v -- config/ip-lists/china.txt
```

Expected: download command prints a line beginning with `Saved ` and ending with `config/ip-lists/china.txt`. The ignored status includes:

```text
!! config/ip-lists/china.txt
```

- [ ] **Step 6: Commit Task 2**

Run:

```sh
git add scripts/update-china-ip-list.sh
git commit -m "feat: add China IPv4 list updater"
```

Expected: commit succeeds. `config/ip-lists/china.txt` remains untracked and ignored.

## Task 3: Extend Offline ocserv Config Rendering

**Files:**
- Modify: `scripts/render-ocserv-conf.sh`

- [ ] **Step 1: Run baseline check that should fail before renderer changes**

Run:

```sh
grep -Fq 'OCSERV_CHINA_ROUTES_ENABLED' scripts/render-ocserv-conf.sh
```

Expected: command exits non-zero because China split-routing support is not implemented yet.

- [ ] **Step 2: Replace `scripts/render-ocserv-conf.sh` with offline route rendering**

Replace the file with this complete content:

```sh
#!/bin/sh
set -eu

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=scripts/common.sh disable=SC1091
. "${SCRIPT_DIR}/common.sh"

ENV_FILE=${ENV_FILE:-"${PROJECT_ROOT}/.env"}
TEMPLATE_FILE=${OCSERV_CONF_TEMPLATE:-"${PROJECT_ROOT}/config/ocserv.conf.template"}
CHINA_ROUTE_MARKER='# @OCSERV_CHINA_IPV4_ROUTES@'

[ -f "${ENV_FILE}" ] || fail "env file not found: ${ENV_FILE}. Copy .env.example to .env first."
[ -f "${TEMPLATE_FILE}" ] || fail "template file not found: ${TEMPLATE_FILE}"

OCSERV_CONF_DIR=${OCSERV_CONF_DIR:-$(env_file_value "${ENV_FILE}" OCSERV_CONF_DIR)}
OCSERV_CONF_DIR="${OCSERV_CONF_DIR:-/etc/ocserv}"
OUTPUT_FILE=${OCSERV_CONF_OUTPUT:-"${OCSERV_CONF_DIR}/ocserv.conf"}

DOMAIN=${DOMAIN:-$(env_file_value "${ENV_FILE}" DOMAIN)}
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-$(env_file_value "${ENV_FILE}" OCSERV_ENABLE_COMPRESSION)}
OCSERV_ENABLE_COMPRESSION=${OCSERV_ENABLE_COMPRESSION:-false}
OCSERV_NO_UDP=${OCSERV_NO_UDP:-$(env_file_value "${ENV_FILE}" OCSERV_NO_UDP)}
OCSERV_NO_UDP=${OCSERV_NO_UDP:-false}
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-$(env_file_value "${ENV_FILE}" OCSERV_MAX_CLIENTS)}
OCSERV_MAX_CLIENTS=${OCSERV_MAX_CLIENTS:-32}

OCSERV_CHINA_ROUTES_ENABLED=${OCSERV_CHINA_ROUTES_ENABLED:-$(env_file_value "${ENV_FILE}" OCSERV_CHINA_ROUTES_ENABLED)}
OCSERV_CHINA_ROUTES_ENABLED=${OCSERV_CHINA_ROUTES_ENABLED:-false}
OCSERV_CHINA_ROUTES_MODE=${OCSERV_CHINA_ROUTES_MODE:-$(env_file_value "${ENV_FILE}" OCSERV_CHINA_ROUTES_MODE)}
OCSERV_CHINA_ROUTES_MODE=${OCSERV_CHINA_ROUTES_MODE:-route}
OCSERV_CHINA_IP_FILE=${OCSERV_CHINA_IP_FILE:-$(env_file_value "${ENV_FILE}" OCSERV_CHINA_IP_FILE)}
OCSERV_CHINA_IP_FILE=${OCSERV_CHINA_IP_FILE:-config/ip-lists/china.txt}

validate_domain DOMAIN "${DOMAIN}"
validate_bool OCSERV_ENABLE_COMPRESSION "${OCSERV_ENABLE_COMPRESSION}"
validate_bool OCSERV_NO_UDP "${OCSERV_NO_UDP}"
validate_bool OCSERV_CHINA_ROUTES_ENABLED "${OCSERV_CHINA_ROUTES_ENABLED}"

case "${OCSERV_CHINA_ROUTES_MODE}" in
    route|no-route)
        ;;
    *)
        fail "OCSERV_CHINA_ROUTES_MODE must be route or no-route: ${OCSERV_CHINA_ROUTES_MODE}"
        ;;
esac

case "${OCSERV_MAX_CLIENTS}" in
    ''|*[!0-9]*)
        fail "OCSERV_MAX_CLIENTS must be a positive integer: ${OCSERV_MAX_CLIENTS}"
        ;;
esac
[ "${OCSERV_MAX_CLIENTS}" -ge 1 ] || fail "OCSERV_MAX_CLIENTS must be at least 1"

TLS_CERT_FILE=${TLS_CERT_FILE:-$(env_file_value "${ENV_FILE}" TLS_CERT_FILE)}
TLS_KEY_FILE=${TLS_KEY_FILE:-$(env_file_value "${ENV_FILE}" TLS_KEY_FILE)}
validate_tls_paths "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"

MARKER_COUNT=$(grep -Fxc "${CHINA_ROUTE_MARKER}" "${TEMPLATE_FILE}" || true)
[ "${MARKER_COUNT}" -eq 1 ] \
    || fail "template must contain exactly one marker line: ${CHINA_ROUTE_MARKER}"

OUTPUT_DIR=$(dirname -- "${OUTPUT_FILE}")
mkdir -p "${OUTPUT_DIR}" 2>/dev/null || fail "cannot create output directory: ${OUTPUT_DIR} (run with sudo)"

TMP_FILE=
CHINA_ROUTE_FILE=

cleanup() {
    [ -z "${TMP_FILE:-}" ] || rm -f "${TMP_FILE}"
    [ -z "${CHINA_ROUTE_FILE:-}" ] || rm -f "${CHINA_ROUTE_FILE}"
}

trap cleanup EXIT HUP INT TERM

TMP_FILE=$(mktemp "${OUTPUT_DIR}/.ocserv.conf.XXXXXX") || fail "failed to create temporary config"
CHINA_ROUTE_FILE=$(mktemp "${OUTPUT_DIR}/.ocserv-china-routes.XXXXXX") || fail "failed to create route temporary file"

CHINA_ROUTE_COUNT=0

if [ "${OCSERV_CHINA_ROUTES_ENABLED}" = true ]; then
    case "${OCSERV_CHINA_IP_FILE}" in
        /*)
            ;;
        *)
            OCSERV_CHINA_IP_FILE="${PROJECT_ROOT}/${OCSERV_CHINA_IP_FILE}"
            ;;
    esac

    validate_regular_file OCSERV_CHINA_IP_FILE "${OCSERV_CHINA_IP_FILE}"

    if ! awk -v mode="${OCSERV_CHINA_ROUTES_MODE}" '
        function mask_octet(bits) {
            if (bits >= 8) return 255
            if (bits <= 0) return 0
            if (bits == 1) return 128
            if (bits == 2) return 192
            if (bits == 3) return 224
            if (bits == 4) return 240
            if (bits == 5) return 248
            if (bits == 6) return 252
            if (bits == 7) return 254
        }

        function prefix_to_mask(prefix, remaining, a, b, c, d) {
            remaining = prefix

            a = mask_octet(remaining)
            remaining -= 8

            b = mask_octet(remaining)
            remaining -= 8

            c = mask_octet(remaining)
            remaining -= 8

            d = mask_octet(remaining)

            return a "." b "." c "." d
        }

        function valid_cidr(value, parts, octets, count, i, prefix) {
            count = split(value, parts, "/")

            if (count != 2 || parts[2] !~ /^[0-9]+$/) {
                return 0
            }

            prefix = parts[2] + 0

            if (prefix < 1 || prefix > 32) {
                return 0
            }

            count = split(parts[1], octets, ".")

            if (count != 4) {
                return 0
            }

            for (i = 1; i <= 4; i++) {
                if (octets[i] !~ /^[0-9]+$/) {
                    return 0
                }

                if (octets[i] + 0 < 0 || octets[i] + 0 > 255) {
                    return 0
                }
            }

            return 1
        }

        BEGIN {
            print "# BEGIN generated China IPv4 routes; do not edit this block"
            print "# Mode: " mode

            if (mode == "no-route") {
                print "route = default"
            }
        }

        {
            line = $0

            sub(/\r$/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)

            if (line == "" || substr(line, 1, 1) == "#") {
                next
            }

            if (!valid_cidr(line)) {
                printf "invalid IPv4 CIDR at list line %d: %s\n", NR, line > "/dev/stderr"
                invalid = 1
                next
            }

            if (seen[line]++) {
                next
            }

            split(line, cidr_parts, "/")
            converted = cidr_parts[1] "/" prefix_to_mask(cidr_parts[2] + 0)

            if (mode == "route") {
                print "route = " converted
            } else {
                print "no-route = " converted
            }

            count++
        }

        END {
            if (invalid) {
                exit 2
            }

            if (count < 1000 || count > 20000) {
                printf "unexpected China IPv4 prefix count: %d\n", count > "/dev/stderr"
                exit 3
            }

            print "# END generated China IPv4 routes; prefixes=" count
        }
    ' "${OCSERV_CHINA_IP_FILE}" > "${CHINA_ROUTE_FILE}"; then
        fail "China IPv4 list validation or conversion failed: ${OCSERV_CHINA_IP_FILE}"
    fi

    case "${OCSERV_CHINA_ROUTES_MODE}" in
        route)
            CHINA_ROUTE_COUNT=$(grep -c '^route = ' "${CHINA_ROUTE_FILE}" || true)
            ;;
        no-route)
            CHINA_ROUTE_COUNT=$(grep -c '^no-route = ' "${CHINA_ROUTE_FILE}" || true)
            ;;
    esac
else
    {
        printf '%s\n' '# BEGIN generated China IPv4 routes'
        printf '%s\n' '# Disabled by OCSERV_CHINA_ROUTES_ENABLED=false'
        printf '%s\n' '# END generated China IPv4 routes'
    } > "${CHINA_ROUTE_FILE}"
fi

awk \
    -v domain="${DOMAIN}" \
    -v enable_compression="${OCSERV_ENABLE_COMPRESSION}" \
    -v no_udp="${OCSERV_NO_UDP}" \
    -v max_clients="${OCSERV_MAX_CLIENTS}" \
    -v china_route_marker="${CHINA_ROUTE_MARKER}" \
    -v china_route_file="${CHINA_ROUTE_FILE}" '
    $0 == china_route_marker {
        while ((getline route_line < china_route_file) > 0) {
            print route_line
        }

        close(china_route_file)
        next
    }

    {
        gsub(/\$\{DOMAIN\}/, domain)

        if ($0 ~ /^[[:space:]]*compression[[:space:]]*=/) {
            print "compression = " enable_compression
            next
        }

        if ($0 ~ /^[[:space:]]*no-udp[[:space:]]*=/) {
            print "no-udp = " no_udp
            next
        }

        if ($0 ~ /^[[:space:]]*max-clients[[:space:]]*=/) {
            sub(/=.*/, "= " max_clients)
        }

        print
    }
' "${TEMPLATE_FILE}" > "${TMP_FILE}"

# shellcheck disable=SC2016
if grep -q '\${DOMAIN}' "${TMP_FILE}"; then
    fail "unrendered DOMAIN placeholder remains in generated config"
fi

if grep -Fq "${CHINA_ROUTE_MARKER}" "${TMP_FILE}"; then
    fail "unrendered China route marker remains in generated config"
fi

chmod 0644 "${TMP_FILE}"

mv "${TMP_FILE}" "${OUTPUT_FILE}"
TMP_FILE=

printf 'Rendered %s from %s using DOMAIN=%s OCSERV_MAX_CLIENTS=%s OCSERV_ENABLE_COMPRESSION=%s OCSERV_NO_UDP=%s OCSERV_CHINA_ROUTES_ENABLED=%s OCSERV_CHINA_ROUTES_MODE=%s CHINA_PREFIXES=%s\n' \
    "${OUTPUT_FILE}" \
    "${TEMPLATE_FILE}" \
    "${DOMAIN}" \
    "${OCSERV_MAX_CLIENTS}" \
    "${OCSERV_ENABLE_COMPRESSION}" \
    "${OCSERV_NO_UDP}" \
    "${OCSERV_CHINA_ROUTES_ENABLED}" \
    "${OCSERV_CHINA_ROUTES_MODE}" \
    "${CHINA_ROUTE_COUNT}"

cleanup
trap - EXIT HUP INT TERM
```

- [ ] **Step 3: Ensure the renderer remains executable and passes syntax checks**

Run:

```sh
chmod +x scripts/render-ocserv-conf.sh
sh -n scripts/render-ocserv-conf.sh
```

Expected: both commands exit zero.

- [ ] **Step 4: Verify the renderer contains no network commands**

Run:

```sh
! grep -Eq '(^|[^A-Za-z0-9_-])(curl|wget)([^A-Za-z0-9_-]|$)' scripts/render-ocserv-conf.sh
```

Expected: command exits zero.

- [ ] **Step 5: Commit Task 3**

Run:

```sh
git add scripts/render-ocserv-conf.sh
git commit -m "feat: render China IPv4 split routes offline"
```

Expected: commit succeeds.

## Task 4: Run Offline Render Success Tests

**Files:**
- Test only: no repository files modified.

- [ ] **Step 1: Create a temporary render test environment**

Run:

```sh
TEST_DIR=$(mktemp -d /tmp/ocserv-china-routes.XXXXXX)
mkdir -p "${TEST_DIR}/ip-lists" "${TEST_DIR}/out"
touch "${TEST_DIR}/fullchain.pem" "${TEST_DIR}/privkey.pem"
awk 'BEGIN {
    for (i = 0; i < 1000; i++) {
        printf "10.%d.%d.0/24\n", int(i / 256), i % 256
    }
}' > "${TEST_DIR}/ip-lists/china.txt"
{
    printf '%s\n' 'DOMAIN=vpn.example.com'
    printf '%s\n' 'OCSERV_CONF_DIR=/etc/ocserv'
    printf 'TLS_CERT_FILE=%s\n' "${TEST_DIR}/fullchain.pem"
    printf 'TLS_KEY_FILE=%s\n' "${TEST_DIR}/privkey.pem"
    printf '%s\n' 'OCSERV_ENABLE_COMPRESSION=false'
    printf '%s\n' 'OCSERV_NO_UDP=false'
    printf '%s\n' 'OCSERV_MAX_CLIENTS=32'
    printf '%s\n' 'OCSERV_CHINA_ROUTES_ENABLED=true'
    printf '%s\n' 'OCSERV_CHINA_ROUTES_MODE=route'
    printf 'OCSERV_CHINA_IP_FILE=%s\n' "${TEST_DIR}/ip-lists/china.txt"
} > "${TEST_DIR}/.env"
```

Expected: command exits zero and creates a temporary `.env` with regular TLS placeholder files.

- [ ] **Step 2: Verify `route` mode**

Run:

```sh
ENV_FILE="${TEST_DIR}/.env" \
OCSERV_CONF_OUTPUT="${TEST_DIR}/out/ocserv-route.conf" \
scripts/render-ocserv-conf.sh

grep -Fqx '# Mode: route' "${TEST_DIR}/out/ocserv-route.conf"
grep -Fqx 'route = 10.0.0.0/255.255.255.0' "${TEST_DIR}/out/ocserv-route.conf"
grep -Fqx '# END generated China IPv4 routes; prefixes=1000' "${TEST_DIR}/out/ocserv-route.conf"
test "$(grep -c '^route = ' "${TEST_DIR}/out/ocserv-route.conf")" -eq 1000
! grep -q '^no-route = ' "${TEST_DIR}/out/ocserv-route.conf"
! grep -F '${DOMAIN}' "${TEST_DIR}/out/ocserv-route.conf"
! grep -F '# @OCSERV_CHINA_IPV4_ROUTES@' "${TEST_DIR}/out/ocserv-route.conf"
```

Expected: render output includes `CHINA_PREFIXES=1000`; all checks exit zero.

- [ ] **Step 3: Verify `no-route` mode**

Run:

```sh
OCSERV_CHINA_ROUTES_MODE=no-route \
ENV_FILE="${TEST_DIR}/.env" \
OCSERV_CONF_OUTPUT="${TEST_DIR}/out/ocserv-no-route.conf" \
scripts/render-ocserv-conf.sh

grep -Fqx '# Mode: no-route' "${TEST_DIR}/out/ocserv-no-route.conf"
grep -Fqx 'route = default' "${TEST_DIR}/out/ocserv-no-route.conf"
grep -Fqx 'no-route = 10.0.0.0/255.255.255.0' "${TEST_DIR}/out/ocserv-no-route.conf"
grep -Fqx '# END generated China IPv4 routes; prefixes=1000' "${TEST_DIR}/out/ocserv-no-route.conf"
test "$(grep -c '^no-route = ' "${TEST_DIR}/out/ocserv-no-route.conf")" -eq 1000
! grep -F '${DOMAIN}' "${TEST_DIR}/out/ocserv-no-route.conf"
! grep -F '# @OCSERV_CHINA_IPV4_ROUTES@' "${TEST_DIR}/out/ocserv-no-route.conf"
```

Expected: render output includes `CHINA_PREFIXES=1000`; `route = default` is present and is not counted as a China prefix.

## Task 5: Run Offline Render Failure Tests

**Files:**
- Test only: no repository files modified.

- [ ] **Step 1: Verify missing route list fails without overwriting output**

Run:

```sh
printf '%s\n' 'sentinel' > "${TEST_DIR}/out/failure.conf"
if OCSERV_CHINA_IP_FILE="${TEST_DIR}/ip-lists/missing.txt" \
    ENV_FILE="${TEST_DIR}/.env" \
    OCSERV_CONF_OUTPUT="${TEST_DIR}/out/failure.conf" \
    scripts/render-ocserv-conf.sh; then
    printf '%s\n' 'missing route list unexpectedly passed' >&2
    exit 1
fi
grep -qx 'sentinel' "${TEST_DIR}/out/failure.conf"
```

Expected: renderer exits non-zero and `failure.conf` still contains exactly `sentinel`.

- [ ] **Step 2: Verify invalid mode fails without overwriting output**

Run:

```sh
printf '%s\n' 'sentinel' > "${TEST_DIR}/out/failure.conf"
if OCSERV_CHINA_ROUTES_MODE=bad \
    ENV_FILE="${TEST_DIR}/.env" \
    OCSERV_CONF_OUTPUT="${TEST_DIR}/out/failure.conf" \
    scripts/render-ocserv-conf.sh; then
    printf '%s\n' 'invalid mode unexpectedly passed' >&2
    exit 1
fi
grep -qx 'sentinel' "${TEST_DIR}/out/failure.conf"
```

Expected: renderer exits non-zero and `failure.conf` still contains exactly `sentinel`.

- [ ] **Step 3: Verify bad CIDR values fail without overwriting output**

Run:

```sh
BAD_LIST="${TEST_DIR}/ip-lists/bad.txt"
{
    printf '%s\n' '0.0.0.0/0'
    printf '%s\n' '999.1.1.0/24'
    printf '%s\n' '1.2.3.0/33'
} > "${BAD_LIST}"
printf '%s\n' 'sentinel' > "${TEST_DIR}/out/failure.conf"
if OCSERV_CHINA_IP_FILE="${BAD_LIST}" \
    ENV_FILE="${TEST_DIR}/.env" \
    OCSERV_CONF_OUTPUT="${TEST_DIR}/out/failure.conf" \
    scripts/render-ocserv-conf.sh; then
    printf '%s\n' 'bad CIDR list unexpectedly passed' >&2
    exit 1
fi
grep -qx 'sentinel' "${TEST_DIR}/out/failure.conf"
```

Expected: renderer exits non-zero and `failure.conf` still contains exactly `sentinel`.

- [ ] **Step 4: Verify missing marker fails without overwriting output**

Run:

```sh
MISSING_MARKER_TEMPLATE="${TEST_DIR}/template-missing-marker.conf"
grep -Fv '# @OCSERV_CHINA_IPV4_ROUTES@' config/ocserv.conf.template > "${MISSING_MARKER_TEMPLATE}"
printf '%s\n' 'sentinel' > "${TEST_DIR}/out/failure.conf"
if OCSERV_CONF_TEMPLATE="${MISSING_MARKER_TEMPLATE}" \
    ENV_FILE="${TEST_DIR}/.env" \
    OCSERV_CONF_OUTPUT="${TEST_DIR}/out/failure.conf" \
    scripts/render-ocserv-conf.sh; then
    printf '%s\n' 'missing marker unexpectedly passed' >&2
    exit 1
fi
grep -qx 'sentinel' "${TEST_DIR}/out/failure.conf"
```

Expected: renderer exits non-zero and `failure.conf` still contains exactly `sentinel`.

- [ ] **Step 5: Verify duplicate marker fails without overwriting output**

Run:

```sh
DUPLICATE_MARKER_TEMPLATE="${TEST_DIR}/template-duplicate-marker.conf"
cp config/ocserv.conf.template "${DUPLICATE_MARKER_TEMPLATE}"
printf '%s\n' '# @OCSERV_CHINA_IPV4_ROUTES@' >> "${DUPLICATE_MARKER_TEMPLATE}"
printf '%s\n' 'sentinel' > "${TEST_DIR}/out/failure.conf"
if OCSERV_CONF_TEMPLATE="${DUPLICATE_MARKER_TEMPLATE}" \
    ENV_FILE="${TEST_DIR}/.env" \
    OCSERV_CONF_OUTPUT="${TEST_DIR}/out/failure.conf" \
    scripts/render-ocserv-conf.sh; then
    printf '%s\n' 'duplicate marker unexpectedly passed' >&2
    exit 1
fi
grep -qx 'sentinel' "${TEST_DIR}/out/failure.conf"
```

Expected: renderer exits non-zero and `failure.conf` still contains exactly `sentinel`.

## Task 6: Run Full Verification and Commit Remaining Changes

**Files:**
- Verify: `.env.example`
- Verify: `.gitignore`
- Verify: `config/ocserv.conf.template`
- Verify: `scripts/update-china-ip-list.sh`
- Verify: `scripts/render-ocserv-conf.sh`

- [ ] **Step 1: Run shell syntax checks**

Run:

```sh
sh -n scripts/update-china-ip-list.sh
sh -n scripts/render-ocserv-conf.sh
```

Expected: both commands exit zero.

- [ ] **Step 2: Run ShellCheck if installed**

Run:

```sh
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck scripts/update-china-ip-list.sh scripts/render-ocserv-conf.sh
else
    printf '%s\n' 'shellcheck not installed; skipping static analysis'
fi
```

Expected: ShellCheck passes, or the command prints `shellcheck not installed; skipping static analysis`.

- [ ] **Step 3: Verify config and ignore invariants**

Run:

```sh
test "$(grep -Fxc '# @OCSERV_CHINA_IPV4_ROUTES@' config/ocserv.conf.template)" -eq 1
grep -Fqx 'OCSERV_CHINA_ROUTES_ENABLED=false' .env.example
grep -Fqx 'OCSERV_CHINA_ROUTES_MODE=route' .env.example
grep -Fqx 'OCSERV_CHINA_IP_FILE=config/ip-lists/china.txt' .env.example
grep -Fqx 'OCSERV_CHINA_IP_URL=https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt' .env.example
git check-ignore -q -- config/ip-lists/china.txt
! git ls-files --error-unmatch config/ip-lists/china.txt >/dev/null 2>&1
```

Expected: all commands exit zero.

- [ ] **Step 4: Verify no automatic update mechanism was added**

Run:

```sh
for path in .github docker docker-compose.yml Dockerfile; do
    [ -e "${path}" ] || continue
    if grep -RInE 'china.*(cron|schedule|workflow_dispatch|on: schedule|curl|wget)' "${path}"; then
        printf '%s\n' "unexpected automatic China route update reference under ${path}" >&2
        exit 1
    fi
done
```

Expected: command exits zero.

- [ ] **Step 5: Review final diff**

Run:

```sh
git status --short
git diff -- .env.example .gitignore config/ocserv.conf.template scripts/update-china-ip-list.sh scripts/render-ocserv-conf.sh
```

Expected: the diff only contains the approved China IPv4 split-routing implementation.

- [ ] **Step 6: Commit any uncommitted implementation changes**

If Tasks 1 through 3 were committed exactly as written, this step should show no staged implementation changes. If a previous task was not committed, run:

```sh
git add .env.example .gitignore config/ocserv.conf.template scripts/update-china-ip-list.sh scripts/render-ocserv-conf.sh
git commit -m "feat: add China IPv4 split routing"
```

Expected: either working tree is already clean, or the final implementation commit succeeds.
