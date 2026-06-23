# China IPv4 Split Routing Design

## Context

This project renders `config/ocserv.conf.template` with values from `.env` into the host-side final ocserv configuration at `${OCSERV_CONF_DIR}/ocserv.conf`. Docker Compose then mounts that generated file into the container as `/etc/ocserv/ocserv.conf:ro`.

China IPv4 route data is external and changes frequently. The selected source is the pre-generated `china.txt` file from the `ip-lists` branch of `gaoyifan/china-operator-ip`. The project must not commit that changing data file. Operators download it locally when they want to enable or refresh split routing.

## Goals

- Add an explicit manual download script for China IPv4 CIDR data.
- Keep config rendering fully offline.
- Support two ocserv route modes:
  - `route`: only China IPv4 prefixes are routed through the VPN.
  - `no-route`: VPN becomes the default route, while China IPv4 prefixes are excluded.
- Convert source CIDR entries such as `1.2.3.0/24` into ocserv-style `1.2.3.0/255.255.255.0` route entries during rendering.
- Fail before replacing the final `ocserv.conf` if inputs are invalid.
- Keep downloaded route data ignored by Git.

## Non-Goals

- Do not commit `config/ip-lists/china.txt`.
- Do not add GitHub Actions, cron, container-start downloads, or any automatic refresh process.
- Do not download route data from `scripts/render-ocserv-conf.sh`.
- Do not modify files inside the running container.
- Do not add IPv6 split routing in this change.

## Architecture

The design has four focused parts.

### `scripts/update-china-ip-list.sh`

This is the only component that performs network access. It reads `OCSERV_CHINA_IP_URL` and `OCSERV_CHINA_IP_FILE` from the environment or `.env`, with production defaults from `.env.example`.

The script downloads the source file into a temporary file in the destination directory, validates that each non-empty non-comment line is an IPv4 CIDR with prefix length `1..32`, removes duplicates while preserving first-seen order, enforces a protective prefix-count range, and atomically replaces the destination file with `mv`.

If any step fails, only temporary files are removed. Any existing destination file remains unchanged.

### `scripts/render-ocserv-conf.sh`

Rendering remains offline. The script reads `.env`, `config/ocserv.conf.template`, and the local `OCSERV_CHINA_IP_FILE` only when split routing is enabled.

When `OCSERV_CHINA_ROUTES_ENABLED=false`, the template marker is replaced with a short disabled comment block and no local route list is required.

When `OCSERV_CHINA_ROUTES_ENABLED=true`, the script validates the local route list, converts CIDR prefixes to dotted netmasks, generates the selected route block, renders the full config to a temporary file, checks for leftover placeholders, and only then atomically replaces the final output.

### `config/ocserv.conf.template`

The template gets exactly one route marker after the existing route/no-route examples:

```ini
# @OCSERV_CHINA_IPV4_ROUTES@
```

The render script must fail unless this marker appears exactly once. The generated `ocserv.conf` must not contain the marker.

### `.env.example` and `.gitignore`

`.env.example` documents these defaults:

```dotenv
OCSERV_CHINA_ROUTES_ENABLED=false
OCSERV_CHINA_ROUTES_MODE=route
OCSERV_CHINA_IP_FILE=config/ip-lists/china.txt
OCSERV_CHINA_IP_URL=https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt
```

`.gitignore` excludes downloaded route lists:

```gitignore
config/ip-lists/*.txt
```

## Route Generation

For `route` mode, generated output is:

```ini
# BEGIN generated China IPv4 routes; do not edit this block
# Mode: route
route = 1.2.3.0/255.255.255.0
# END generated China IPv4 routes; prefixes=N
```

For `no-route` mode, generated output is:

```ini
# BEGIN generated China IPv4 routes; do not edit this block
# Mode: no-route
route = default
no-route = 1.2.3.0/255.255.255.0
# END generated China IPv4 routes; prefixes=N
```

The generated block is the single source of dynamic China IPv4 route entries. The renderer must not append dynamic routes anywhere else.

## Validation and Error Handling

`OCSERV_CHINA_ROUTES_ENABLED` must be `true` or `false`.

`OCSERV_CHINA_ROUTES_MODE` must be `route` or `no-route`.

IPv4 CIDR validation must reject:

- Empty effective lists.
- Prefix length `0`.
- Prefix length greater than `32`.
- Non-numeric octets.
- Octets outside `0..255`.
- Lines that are not a single IPv4 CIDR after trimming whitespace.

The protective accepted prefix-count range is `1000..20000`. Error messages should describe violations as an unexpected prefix count, not as a definitive upstream-data error.

When split routing is enabled, rendering must fail if:

- The local route list path is empty.
- The route list does not exist.
- The route list is not a regular file.
- The route list has invalid CIDR entries.
- The valid prefix count is outside `1000..20000`.
- The template marker is missing or duplicated.
- The rendered file still contains `${DOMAIN}`.
- The rendered file still contains `# @OCSERV_CHINA_IPV4_ROUTES@`.

All these checks happen before `mv` replaces the final `ocserv.conf`.

## Testing

Syntax checks:

```sh
sh -n scripts/update-china-ip-list.sh
sh -n scripts/render-ocserv-conf.sh
```

If ShellCheck is available:

```sh
shellcheck scripts/update-china-ip-list.sh scripts/render-ocserv-conf.sh
```

Manual download verification:

```sh
./scripts/update-china-ip-list.sh
test -s config/ip-lists/china.txt
git status --short --ignored config/ip-lists/china.txt
git check-ignore -v config/ip-lists/china.txt
```

The ignored status should show:

```text
!! config/ip-lists/china.txt
```

Offline render tests should use a temporary `.env`, temporary output file, temporary regular files for `TLS_CERT_FILE` and `TLS_KEY_FILE`, and a generated local route list with at least 1000 valid prefixes. Successful cases must cover both `route` and `no-route` modes.

Failure tests must cover:

- Enabled split routing with a missing route list.
- Invalid route mode.
- Bad CIDR values, including `0.0.0.0/0`, `999.1.1.0/24`, and `1.2.3.0/33`.
- Missing template marker.
- Duplicate template marker.
- Failure leaving an existing output file unchanged. Each failure test should write a sentinel output file before running the renderer and verify that the sentinel remains after failure.

Final rendered output checks:

```sh
! grep -F '${DOMAIN}' /tmp/ocserv-test/ocserv.conf
! grep -F '# @OCSERV_CHINA_IPV4_ROUTES@' /tmp/ocserv-test/ocserv.conf
```

## Acceptance Criteria

- `update-china-ip-list.sh` is the only networking component for this feature.
- `render-ocserv-conf.sh` does not execute `curl`, `wget`, or fallback downloads.
- Enabling split routing without a valid local list fails.
- `china.txt` is ignored and not committed.
- `route` and `no-route` modes are both verified.
- The template marker appears exactly once in the template and never in rendered output.
- Render failures do not replace the previous output file.
- No automatic update mechanism is added.
