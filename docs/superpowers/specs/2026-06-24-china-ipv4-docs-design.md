# China IPv4 Split Routing Documentation Design

## Context

China IPv4 split routing has been implemented with a deliberate boundary:

- `scripts/update-china-ip-list.sh` is the only component that downloads the external China IPv4 CIDR list.
- `scripts/render-ocserv-conf.sh` renders offline from `.env`, `config/ocserv.conf.template`, and the local `OCSERV_CHINA_IP_FILE`.
- `config/ip-lists/*.txt` is ignored because the downloaded list is external changing data.

The repository now needs user-facing and architecture documentation that describes how to operate and reason about this feature without changing the implementation.

## Goals

- Update `docs/README.md` so operators can enable, refresh, render, and restart China IPv4 split routing safely.
- Update `docs/project-architecture.md` so maintainers understand the split between download-time network access and offline render-time validation.
- Document the four `OCSERV_CHINA_*` variables already present in `.env.example`.
- Document both route modes:
  - `route`: route China IPv4 prefixes through the VPN.
  - `no-route`: route all traffic through the VPN except China IPv4 prefixes.
- Make failure behavior explicit: enabled split routing fails when the local list is missing, invalid, empty, or has an unexpected prefix count.
- Keep downloaded route data out of Git and out of documentation examples as committed content.

## Non-Goals

- Do not change shell scripts, templates, Docker Compose files, or runtime behavior.
- Do not add a new standalone China split-routing document for this pass.
- Do not document automatic updates, cron, GitHub Actions schedules, or container-start downloads.
- Do not suggest committing `config/ip-lists/china.txt`.
- Do not add IPv6 split-routing documentation.

## Documentation Approach

Use the existing documentation surfaces instead of adding a new page.

### `docs/README.md`

Add operator guidance in the existing setup and configuration sections:

- Mention the manual list refresh command near the environment/config preparation flow.
- Add the `OCSERV_CHINA_*` variables to the environment variable reference table.
- Add `scripts/update-china-ip-list.sh` to the script reference table.
- Explain the normal operational sequence:

```sh
./scripts/update-china-ip-list.sh
sudo ./scripts/render-ocserv-conf.sh
docker compose restart ocserv
```

- State that `render-ocserv-conf.sh` does not download the list. If split routing is enabled and the local file is absent or invalid, rendering fails before replacing the existing final config.
- Keep examples concise and production-oriented.

### `docs/project-architecture.md`

Update the architecture description to include the new data flow:

```text
.env
config/ocserv.conf.template
config/ip-lists/china.txt   # optional local ignored data
        |
        v
scripts/render-ocserv-conf.sh
        |
        v
${OCSERV_CONF_DIR}/ocserv.conf
```

Document these architecture boundaries:

- `update-china-ip-list.sh` is the only networking component for China IPv4 route data.
- `render-ocserv-conf.sh` is offline and only reads local files.
- The template marker `# @OCSERV_CHINA_IPV4_ROUTES@` is the only dynamic route block insertion point.
- The generated host config is mounted read-only into the container, preserving the current host-rendered configuration model.
- `config/ip-lists/*.txt` is generated local data and should remain ignored.

## Placement

Proposed `docs/README.md` edits:

- Extend the setup/config preparation section with the optional China IPv4 route-list refresh step.
- Extend `4.3 环境变量一览` with the four China IPv4 variables.
- Extend `6.4 配置脚本` with the updater script and updated renderer behavior.

Proposed `docs/project-architecture.md` edits:

- Extend the environment variable table with the four China IPv4 variables.
- Extend the configuration rendering subsection with the optional local route-list input and offline renderer boundary.
- Extend the project file index with `scripts/update-china-ip-list.sh` and `config/ip-lists/*.txt`.

## Validation

Documentation validation should be text-level and repository-level:

```sh
rg -n "OCSERV_CHINA|update-china-ip-list|config/ip-lists|@OCSERV_CHINA_IPV4_ROUTES" docs/README.md docs/project-architecture.md
git diff --check
```

Expected results:

- Both docs mention the `OCSERV_CHINA_*` configuration surface.
- User docs include the manual refresh/render/restart workflow.
- Architecture docs identify the updater as the only networking component and the renderer as offline.
- No documentation instructs users to commit `config/ip-lists/china.txt`.
- No implementation files are modified by this documentation task.

## Acceptance Criteria

- `docs/README.md` explains how to enable and refresh China IPv4 split routing.
- `docs/README.md` documents `route` and `no-route` mode semantics.
- `docs/README.md` documents failure behavior when enabled routing lacks a valid local list.
- `docs/project-architecture.md` documents the download/render separation.
- `docs/project-architecture.md` documents the local ignored route-list file and template marker role.
- Documentation does not introduce automatic update workflows.
- Documentation-only changes are committed separately from implementation changes.
