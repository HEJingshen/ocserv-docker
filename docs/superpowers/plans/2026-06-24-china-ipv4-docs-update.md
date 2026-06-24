# China IPv4 Documentation Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the user and architecture documentation for the implemented China IPv4 split-routing feature without changing runtime behavior.

**Architecture:** This is a documentation-only change. `docs/README.md` gets operator-facing setup, refresh, environment variable, and script reference guidance. `docs/project-architecture.md` gets maintainer-facing data-flow and responsibility-boundary guidance for manual download versus offline rendering.

**Tech Stack:** Markdown, existing repository documentation style, `rg`, `git diff --check`, Git.

---

## File Structure

- Create: `docs/superpowers/plans/2026-06-24-china-ipv4-docs-update.md`
  - This implementation plan.
- Modify: `docs/README.md`
  - Operator workflow, environment variables, and script table.
- Modify: `docs/project-architecture.md`
  - Architecture boundary, data flow, environment variables, and project file index.

No shell scripts, templates, Docker Compose files, `.env.example`, route-list files, or implementation files are modified by this plan.

Use the actual implemented variable names from `.env.example` and the renderer:

- `OCSERV_CHINA_ROUTES_ENABLED`
- `OCSERV_CHINA_ROUTES_MODE`
- `OCSERV_CHINA_IP_FILE`
- `OCSERV_CHINA_IP_URL`

Do not document automatic updates, cron, GitHub Actions schedules, container-start downloads, IPv6 split routing, or committing `config/ip-lists/china.txt`.

## Task 1: Update `docs/README.md` Operator Workflow

**Files:**
- Modify: `docs/README.md`

- [ ] **Step 1: Add optional China IPv4 split-routing setup under `2.1 配置环境变量并准备配置`**

Add a short optional subsection after the current paragraph `基础部署变量以 [../.env.example](../.env.example) 为准。`:

```markdown
如需启用 China IPv4 split routing，在 `.env` 中设置：

```dotenv
OCSERV_CHINA_ROUTES_ENABLED=true
OCSERV_CHINA_ROUTES_MODE=route
```

`route` 模式只让 China IPv4 prefixes 通过 VPN；`no-route` 模式会下发默认路由，但把 China IPv4 prefixes 排除在 VPN 外。启用后先手动下载本地 CIDR 列表，再渲染配置并重启服务：

```sh
./scripts/update-china-ip-list.sh
sudo ./scripts/render-ocserv-conf.sh
docker compose restart ocserv
```

`render-ocserv-conf.sh` 不会联网下载列表，只读取本地 `OCSERV_CHINA_IP_FILE`。如果启用分流但本地列表缺失、非法、为空或 prefix count 不符合预期，渲染会失败，并且不会替换已有最终配置。
```

- [ ] **Step 2: Keep the existing quick-check commands unchanged**

Verify that the existing block still follows the new optional split-routing text:

```sh
docker compose config
set -a; . .env; set +a
sudo ls -l "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"
```

Expected: the quick-check block remains present and unchanged.

## Task 2: Update `docs/README.md` Environment and Script References

**Files:**
- Modify: `docs/README.md`

- [ ] **Step 1: Add China IPv4 variables to `4.3 环境变量一览`**

Add these rows after `OCSERV_MAX_CLIENTS`:

```markdown
| `OCSERV_CHINA_ROUTES_ENABLED` | `false` | 是否从本地 China IPv4 CIDR 列表生成分流路由 |
| `OCSERV_CHINA_ROUTES_MODE` | `route` | `route`：China IPv4 prefixes 通过 VPN；`no-route`：默认全流量走 VPN，但 China IPv4 prefixes 不走 VPN |
| `OCSERV_CHINA_IP_FILE` | `config/ip-lists/china.txt` | 本地 China IPv4 CIDR 列表路径；相对路径按仓库根目录解析 |
| `OCSERV_CHINA_IP_URL` | `https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt` | 仅供 `scripts/update-china-ip-list.sh` 手动下载使用，渲染阶段不会访问 |
```

- [ ] **Step 2: Add the updater script to `6.4 配置脚本`**

Add `scripts/update-china-ip-list.sh` next to the renderer:

```markdown
| `scripts/update-china-ip-list.sh` | 手动下载、校验、去重并原子写入本地 China IPv4 CIDR 列表 |
| `scripts/render-ocserv-conf.sh` | 从 `.env`、模板和本地 route list 离线渲染 `/etc/ocserv/ocserv.conf`；启用 China IPv4 分流时不会联网兜底 |
```

- [ ] **Step 3: Verify README references**

Run:

```sh
rg -n "OCSERV_CHINA|update-china-ip-list|config/ip-lists" docs/README.md
```

Expected: output includes the optional setup workflow, the four environment variable rows, and the script table entry.

## Task 3: Update `docs/project-architecture.md` Configuration Boundary

**Files:**
- Modify: `docs/project-architecture.md`

- [ ] **Step 1: Add China IPv4 variables to the main environment table**

Add the same four implemented variables after `OCSERV_MAX_CLIENTS`:

```markdown
| `OCSERV_CHINA_ROUTES_ENABLED` | `false` | 是否从本地 China IPv4 CIDR 列表生成分流路由 |
| `OCSERV_CHINA_ROUTES_MODE` | `route` | `route` 生成 China IPv4 `route`；`no-route` 生成 `route = default` 和 China IPv4 `no-route` |
| `OCSERV_CHINA_IP_FILE` | `config/ip-lists/china.txt` | 本地 route list，渲染阶段只读此文件 |
| `OCSERV_CHINA_IP_URL` | `https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt` | 仅由 `scripts/update-china-ip-list.sh` 手动下载使用 |
```

- [ ] **Step 2: Replace the simple configuration rendering diagram with the split data flow**

Replace:

```text
.env DOMAIN ──▶ config/ocserv.conf.template ──▶ /etc/ocserv/ocserv.conf
```

with:

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

- [ ] **Step 3: Add architecture boundary paragraphs after the data flow**

Add concise paragraphs stating:

```markdown
China IPv4 route data 的下载和渲染职责分离：`scripts/update-china-ip-list.sh` 是唯一访问网络下载 China IPv4 route data 的组件；`scripts/render-ocserv-conf.sh` 是 offline renderer，只读取本地 `.env`、`config/ocserv.conf.template` 和本地 `OCSERV_CHINA_IP_FILE`。

模板中的 `# @OCSERV_CHINA_IPV4_ROUTES@` 是唯一动态路由块插入点。生成后的 `${OCSERV_CONF_DIR}/ocserv.conf` 继续以只读方式挂载到容器内 `/etc/ocserv/ocserv.conf`，保持现有 host-rendered configuration model。
```

- [ ] **Step 4: Keep existing mount documentation consistent**

Verify that the volume table still states:

```markdown
| `${OCSERV_CONF_DIR}/ocserv.conf` | `/etc/ocserv/ocserv.conf` | `ro`（只读） | 渲染后的主配置文件 |
```

Expected: the read-only host-rendered model remains documented.

## Task 4: Update `docs/project-architecture.md` File Index

**Files:**
- Modify: `docs/project-architecture.md`

- [ ] **Step 1: Add the updater script to the scripts tree**

Add:

```text
│   ├── update-china-ip-list.sh         # 手动下载并校验本地 China IPv4 route list
```

near `render-ocserv-conf.sh`.

- [ ] **Step 2: Add the ignored route-list directory under `config/`**

Change the `config/` tree to:

```text
├── config/                             # 配置文件目录
│   ├── ocserv.conf.template            # ocserv 完整配置模板
│   └── ip-lists/                       # 本地下载的 route list（*.txt 不提交）
│       └── china.txt                   # China IPv4 CIDR 列表示例路径，实际文件由部署机器生成
```

Do not document `config/ip-lists/china.txt` as committed repository content.

## Task 5: Validate Documentation-Only Scope

**Files:**
- Inspect: `docs/README.md`
- Inspect: `docs/project-architecture.md`

- [ ] **Step 1: Run required content search**

Run:

```sh
rg -n "OCSERV_CHINA|update-china-ip-list|config/ip-lists|@OCSERV_CHINA_IPV4_ROUTES" docs/README.md docs/project-architecture.md
```

Expected: both docs mention the China IPv4 configuration surface; README includes the operator workflow; architecture docs include the offline renderer boundary and template marker.

- [ ] **Step 2: Run whitespace validation**

Run:

```sh
git diff --check
```

Expected: no output and exit code 0.

- [ ] **Step 3: Verify implementation-stage modified files**

Run:

```sh
git diff --name-only HEAD
```

Expected output after the plan commit:

```text
docs/README.md
docs/project-architecture.md
```

- [ ] **Step 4: Confirm excluded content is absent**

Run:

```sh
rg -n "cron|schedule|GitHub Actions.*China|container.*download|IPv6 split|git add .*china.txt|commit .*china.txt" docs/README.md docs/project-architecture.md
```

Expected: no new automatic update workflow, IPv6 split-routing guidance, or instruction to commit route-list data.

## Task 6: Commit Documentation Updates

**Files:**
- Modify: `docs/README.md`
- Modify: `docs/project-architecture.md`

- [ ] **Step 1: Inspect final diff**

Run:

```sh
git diff -- docs/README.md docs/project-architecture.md
```

Expected: only documentation prose/table/tree changes related to China IPv4 split routing.

- [ ] **Step 2: Commit final documentation update**

Run:

```sh
git add docs/README.md docs/project-architecture.md
git commit -m "docs: document China IPv4 split routing"
```

Expected: commit succeeds and does not include implementation files.
