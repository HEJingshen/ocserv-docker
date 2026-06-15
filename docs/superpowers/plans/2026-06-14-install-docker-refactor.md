# install-docker.sh 重构实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 还掉 install-docker.sh 的有界技术债——补 CI 护栏、修错误可见性、消除重复代码、修复 daemon.json 覆盖 bug，使脚本更安全、更可维护、更可测。

**Architecture:** 最小化行为变更的渐进式重构。按依赖排序：先删死依赖 → 加 run_install helper → 用 helper 重构 probe/install/daemon → 最后补 CI lint（把所有改动一起 lint）。每个 Task 产出独立可验证的 commit。

**Tech Stack:** Bash 4.3+（`declare -A`、`wait -n`、`[[ =~ ]]`）、shellcheck、GitHub Actions、python3/jq/sed（daemon.json 三级降级）。

**Spec:** `docs/superpowers/specs/2026-06-14-install-docker-refactor-design.md`

**Branch:** `refactor/install-docker-cleanup`（已创建，spec 已提交于 `13741bf`）

---

## Spec 偏差说明（重要）

Spec §三 P0-1 提出"`.github/workflows/source-cache.yml` 的 `paths:` 触发器追加 `install-docker.sh` 和 `scripts/occ`"。**本计划修正此偏差**：`source-cache.yml` 是镜像构建入口，`install-docker.sh` 在 `.dockerignore` L24 中被明确排除（非镜像构建链），改动它**不应**触发镜像重建。因此：
- ✅ 执行：`ocserv.yml` 的 `validate` job 加 `bash -n` + `shellcheck`（每次构建都跑，能抓 lint 回归）
- ❌ 不执行：`source-cache.yml` 的 `paths:` 不加 `install-docker.sh`/`scripts/occ`

---

## File Structure

| 文件 | 操作 | 责任 |
|------|------|------|
| `install-docker.sh` | Modify（主体） | P1-4 删死依赖、P0-2 run_install、P1-2 probe 去重、P1-3 Oracle 独立、P1-1 daemon.json、P0-1 shellcheck 修复、P2 全部 |
| `scripts/occ` | Modify（仅 lint 修复） | P0-1 shellcheck 报错修复 |
| `.github/workflows/ocserv.yml` | Modify | P0-1 加 bash 类脚本的 lint |
| `docs/project-architecture.md` | Modify | P0-1 修虚假声明 |
| `.shellcheckrc` | Create | P2-2 项目级 shellcheck 配置 |

---

## Task 1: P1-4 删死依赖 source common.sh

**Files:**
- Modify: `install-docker.sh:9-13`

**背景**：L10-13 软 source `scripts/common.sh`，但全文件 0 引用其任何符号（`fail`/`env_file_value`/`validate_*` 全零）。L9 的 `SCRIPT_DIR` 仅用于 source，无其他用途。删掉让脚本完全 standalone。

- [ ] **Step 1: 删 source 块**

编辑 `install-docker.sh`，删除 L9-13 这 5 行：

```bash
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/scripts/common.sh" ]]; then
  # shellcheck source=scripts/common.sh
  . "${SCRIPT_DIR}/scripts/common.sh"
fi
```

删除后，`set -euo pipefail`（L7）后面直接是空行 + `# --- 颜色与日志` 注释（原 L15，删除后行号上移）。

- [ ] **Step 2: 验证 SCRIPT_DIR 无其他引用**

Run: `grep -n 'SCRIPT_DIR' install-docker.sh`
Expected: 无输出（零匹配）。若有匹配，说明有其他地方用它，需保留——此时停止并回报。

- [ ] **Step 3: 语法检查**

Run: `bash -n install-docker.sh`
Expected: 无输出（语法 OK）。

- [ ] **Step 4: standalone 验证（模拟 curl|bash）**

Run: `bash install-docker.sh --help`
Expected: 打印帮助文本到 stderr，退出码 0。确认不报 `common.sh: No such file` 之类错误。

- [ ] **Step 5: Commit**

```bash
git add install-docker.sh
git commit -m "refactor(install-docker): remove dead dependency on common.sh

scripts/common.sh is sourced (L10-13) but none of its symbols (fail,
env_file_value, validate_*, run_editor_command, PROJECT_ROOT) are used
anywhere in install-docker.sh — 0 references confirmed via grep.

Removing the source + SCRIPT_DIR (only used by the source) makes the
script fully standalone for curl|bash usage."
```

---

## Task 2: P0-2 引入 run_install helper

**Files:**
- Modify: `install-docker.sh`（加 helper 定义 + 改造所有安装命令）

**背景**：6 处 bare 静默安装（L361/362/384/385/421/466）在 `set -e` 下失败时静默退出，用户看不到 apt/dnf 报错。引入 `run_install` helper：成功静默（DEBUG=false 默认，保持现有体验），失败时 `log_error` 可见。同时为 P2-4 的 `--debug` 预留扩展点。

### Step 1: 加 DEBUG 变量声明

- [ ] **Step 1a: 在状态变量区加 DEBUG**

编辑 `install-docker.sh`，找到状态变量行（Task 1 后已上移，原文 L52）：

```bash
TMPDIR_BASE="" SKIP_CLOUD=false FORCE_INSTALL=false NO_MIRROR=false YES_MODE=false
```

改为：

```bash
TMPDIR_BASE="" SKIP_CLOUD=false FORCE_INSTALL=false NO_MIRROR=false YES_MODE=false DEBUG=false
```

### Step 2: 定义 run_install helper

- [ ] **Step 2a: 在 bg_* helpers 之前插入 run_install**

找到 `# --- 并发任务限制` 注释（原文 L54），在其**之前**插入：

```bash
# --- 安装命令执行封装 (成功静默，失败可见；--debug 时全可见) ---
run_install() {
  if [[ "${DEBUG:-false}" == true ]]; then
    "$@" || { log_error "命令失败 (退出码 $?): $*"; return 1; }
  else
    "$@" >/dev/null 2>&1 || { log_error "命令失败，请手动执行查看详情: $*"; return 1; }
  fi
}
```

### Step 3: 改造 install_docker_apt 的安装命令

- [ ] **Step 3a: 改 L361-362（apt-get update + install 前置依赖）**

找到（install_docker_apt 内）：

```bash
  apt-get update -y >/dev/null 2>&1
  apt-get install -y ca-certificates curl gnupg >/dev/null 2>&1
```

改为：

```bash
  run_install apt-get update -y
  run_install apt-get install -y ca-certificates curl gnupg
```

- [ ] **Step 3b: 改 L384-385（apt-get update + install docker-ce）**

找到：

```bash
  apt-get update -y >/dev/null 2>&1
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
```

改为：

```bash
  run_install apt-get update -y
  run_install apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### Step 4: 改造 install_docker_rpm 的安装命令

- [ ] **Step 4a: 改 L417（yum-utils，有 || true 保护）**

找到：

```bash
  $pkg_mgr install -y yum-utils >/dev/null 2>&1 || true
```

改为：

```bash
  run_install "$pkg_mgr" install -y yum-utils || true
```

- [ ] **Step 4b: 改 L418（libnftables，有 || true 保护）**

找到：

```bash
  [[ "$base_ver" =~ ^(9|10)$ ]] && $pkg_mgr install -y libnftables >/dev/null 2>&1 || true
```

改为：

```bash
  [[ "$base_ver" =~ ^(9|10)$ ]] && run_install "$pkg_mgr" install -y libnftables || true
```

- [ ] **Step 4c: 改 L420-421（fallback install 链）**

找到：

```bash
  $pkg_mgr install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest >/dev/null 2>&1 || \
  $pkg_mgr install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1
```

改为：

```bash
  run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest || \
  run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io
```

### Step 5: 改造 Oracle 分支（ol）的安装命令

- [ ] **Step 5a: 改 L456（dnf-plugins-core，有 || true）**

找到：

```bash
      dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
```

改为：

```bash
      run_install dnf install -y dnf-plugins-core || true
```

- [ ] **Step 5b: 改 L465-466（fallback install 链）**

找到：

```bash
      dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest >/dev/null 2>&1 || \
      dnf install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1
```

改为：

```bash
      run_install dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest || \
      run_install dnf install -y docker-ce docker-ce-cli containerd.io
```

### Step 6: 改造 TencentOS 分支的安装命令

- [ ] **Step 6a: 改 L473（fallback install 链）**

找到：

```bash
        $pkg_mgr install -y docker-ce --nobest >/dev/null 2>&1 || $pkg_mgr install -y docker >/dev/null 2>&1
```

改为：

```bash
        run_install "$pkg_mgr" install -y docker-ce --nobest || run_install "$pkg_mgr" install -y docker
```

### Step 7: 改造 systemctl/service 启动命令

**注意**：systemctl/service 启动命令保留 `|| true`（容错设计，不强求成功），但改用 `run_install` 统一失败时的可见性。

- [ ] **Step 7a: 改 L476（tencentos systemctl）**

找到：

```bash
      command -v systemctl &>/dev/null && systemctl enable --now docker >/dev/null 2>&1 || true
```

改为：

```bash
      command -v systemctl &>/dev/null && run_install systemctl enable --now docker || true
```

- [ ] **Step 7b: 改 L485-489（install_docker 的 systemctl/service）**

找到：

```bash
  if command -v systemctl &>/dev/null; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  elif command -v service &>/dev/null; then
    service docker start >/dev/null 2>&1 || true
  fi
```

改为：

```bash
  if command -v systemctl &>/dev/null; then
    run_install systemctl enable --now docker || true
  elif command -v service &>/dev/null; then
    run_install service docker start || true
  fi
```

### Step 8: 验证

- [ ] **Step 8a: 语法检查**

Run: `bash -n install-docker.sh`
Expected: 无输出。

- [ ] **Step 8b: 确认无遗漏的 bare 安装命令**

Run: `grep -n 'install.*>/dev/null' install-docker.sh | grep -v run_install`
Expected: 无输出（所有安装命令都已走 run_install）。若仍有匹配，说明遗漏，需补改。

- [ ] **Step 8c: 确认 run_install 已被使用**

Run: `grep -c 'run_install' install-docker.sh`
Expected: 输出 ≥ 8（1 个定义 + 7+ 处调用）。

- [ ] **Step 8d: 功能验证 --help**

Run: `bash install-docker.sh --help`
Expected: 打印帮助，退出码 0。

- [ ] **Step 9: Commit**

```bash
git add install-docker.sh
git commit -m "refactor(install-docker): add run_install helper for error visibility

6 bare silent install commands (apt-get/dnf install >/dev/null 2>&1)
masked real failures under set -e: installation failure = silent exit
with no apt/dnf error output.

run_install helper: success stays silent (DEBUG=false, preserves UX),
failure now logs the failed command via log_error + returns 1.

Also covers the || true-protected install/start commands for uniform
failure visibility. DEBUG toggle is groundwork for P2-4 --debug mode."
```

---

## Task 3: P1-2 抽 reduce_probe_results 消除重复

**Files:**
- Modify: `install-docker.sh`

**背景**：`probe_pkg_mirrors` L231-242 ≡ `probe_docker_mirrors` L294-305 逐字相同（reduce 循环）。抽 helper 消除。

### Step 1: 加 HTTP_OK_CODES 常量

- [ ] **Step 1a: 在 readonly 常量区加 HTTP_OK_CODES**

找到（原 L46 附近，DOCKER_MIRROR_PROBE_COUNT 定义后）：

```bash
readonly DOCKER_MIRROR_PROBE_COUNT=3
```

在其后加一行：

```bash
readonly HTTP_OK_CODES='^(200|401|403|404|301|302)$'
```

### Step 2: 定义 reduce_probe_results helper

- [ ] **Step 2a: 在 run_install helper 之后插入**

找到 `# --- 安装命令执行封装` 块的结尾（run_install 函数后的空行），在其后、`# --- 并发任务限制` 之前插入：

```bash
# --- 探测结果归约 (从 tmpdir 选出延迟最小的 label) ---
# 输出: "<label> <time_ms>"（成功）或 return 1（无有效结果）
reduce_probe_results() {
  local tmpdir="$1"
  local best_label="" best_time="" found_any=false
  for f in "$tmpdir"/*; do
    [[ -f "$f" ]] || continue
    local val; val=$(cat "$f" 2>/dev/null) || continue
    [[ -z "$val" || ! "$val" =~ ^[0-9]+\.?[0-9]*$ ]] && continue
    found_any=true
    local label="${f##*/}"; label="${label%_*}"
    if [[ -z "$best_time" ]] || awk "BEGIN{exit !(${val} < ${best_time})}"; then
      best_time="$val"; best_label="$label"
    fi
  done
  [[ "$found_any" == true ]] && echo "$best_label $best_time" || return 1
}
```

### Step 3: 改造 probe_pkg_mirrors

- [ ] **Step 3a: 用 reduce_probe_results 替换内联 reduce 循环**

找到 `probe_pkg_mirrors` 的 reduce 块（原 L231-252）：

```bash
  local best_label="" best_time=""
  local found_any=false
  for f in "$tmpdir"/*; do
    [[ -f "$f" ]] || continue
    local val; val=$(cat "$f" 2>/dev/null) || continue
    [[ -z "$val" || ! "$val" =~ ^[0-9]+\.?[0-9]*$ ]] && continue
    found_any=true
    local label="${f##*/}"; label="${label%_*}"
    if [[ -z "$best_time" ]] || awk "BEGIN{exit !(${val} < ${best_time})}"; then
      best_time="$val"; best_label="$label"
    fi
  done

  rm -rf "$tmpdir"

  if [[ -n "$best_label" && "$found_any" == true ]]; then
    PKG_MIRROR="$best_label"
    log_info "✅ 最快包镜像源: $best_label (${MIRRORS[$best_label]}) | ${best_time}ms"
    return 0
  fi

  return 1
```

替换为：

```bash
  local result
  result=$(reduce_probe_results "$tmpdir") || { rm -rf "$tmpdir"; return 1; }
  rm -rf "$tmpdir"

  local best_label best_time
  read -r best_label best_time <<< "$result"
  PKG_MIRROR="$best_label"
  log_info "✅ 最快包镜像源: $best_label (${MIRRORS[$best_label]}) | ${best_time}ms"
  return 0
```

### Step 4: 改造 probe_docker_mirrors

- [ ] **Step 4a: 用 reduce_probe_results 替换内联 reduce 循环**

找到 `probe_docker_mirrors` 的 reduce 块（原 L294-316）：

```bash
  local best_label="" best_time=""
  local found_any=false
  for f in "$tmpdir"/*; do
    [[ -f "$f" ]] || continue
    local val; val=$(cat "$f" 2>/dev/null) || continue
    [[ -z "$val" || ! "$val" =~ ^[0-9]+\.?[0-9]*$ ]] && continue
    found_any=true
    local label="${f##*/}"; label="${label%_*}"
    if [[ -z "$best_time" ]] || awk "BEGIN{exit !(${val} < ${best_time})}"; then
      best_time="$val"; best_label="$label"
    fi
  done

  rm -rf "$tmpdir"

  if [[ -n "$best_label" && "$found_any" == true ]]; then
    DM_BEST_HOST="$best_label"
    for url in "${DOCKER_MIRROR_URLS[@]}"; do
      [[ "$url" == *"$best_label"* ]] && { DM_BEST_URL="$url"; break; }
    done
    log_info "✅ 最快Docker加速源: $best_label | ${best_time}ms"
    return 0
  fi
```

替换为：

```bash
  local result
  result=$(reduce_probe_results "$tmpdir") || { rm -rf "$tmpdir"; return 1; }
  rm -rf "$tmpdir"

  local best_label best_time
  read -r best_label best_time <<< "$result"
  DM_BEST_HOST="$best_label"
  for url in "${DOCKER_MIRROR_URLS[@]}"; do
    [[ "$url" == *"$best_label"* ]] && { DM_BEST_URL="$url"; break; }
  done
  log_info "✅ 最快Docker加速源: $best_label | ${best_time}ms"
  return 0
```

**注意**：替换后，`probe_docker_mirrors` 后面紧跟的"探测全部失败时，使用保底加速源"分支（原 L318 起）仍保留——`reduce_probe_results` 失败时 `return 1` 由前面的 `|| { rm -rf "$tmpdir"; return 1; }` 捕获，会直接返回。**这是一个行为差异需确认**：原代码在 reduce 失败时是 fallthrough 到保底源分支，而新代码 `return 1` 退出函数，不会执行保底源逻辑。

**修正**：保底源逻辑在 reduce 失败时仍需执行。改为：

```bash
  local result best_label best_time
  result=$(reduce_probe_results "$tmpdir")
  rm -rf "$tmpdir"

  if [[ -n "$result" ]]; then
    read -r best_label best_time <<< "$result"
    DM_BEST_HOST="$best_label"
    for url in "${DOCKER_MIRROR_URLS[@]}"; do
      [[ "$url" == *"$best_label"* ]] && { DM_BEST_URL="$url"; break; }
    done
    log_info "✅ 最快Docker加速源: $best_label | ${best_time}ms"
    return 0
  fi
```

这样 `result` 为空（reduce 失败 return 1 时 `$(...)` 捕获空）时，跳过 if 块，继续执行下面的保底源分支。

### Step 5: 用 HTTP_OK_CODES 常量替换重复的字面量

- [ ] **Step 5a: probe_docker_mirrors 中的 L282**

找到：

```bash
        [[ "$http_code" =~ ^(200|401|403|404|301|302)$ ]] || exit 0
```

改为：

```bash
        [[ "$http_code" =~ $HTTP_OK_CODES ]] || exit 0
```

（注意：去掉引号让正则按变量展开。shellcheck 可能报 SC2076，此时加 `# shellcheck disable=SC2076` 或保持原字面量。**如果 shellcheck 报错，保持字面量不改**——这条是可选优化，非必须。）

- [ ] **Step 5b: probe_docker_mirrors fallback 分支的 L325**

找到（保底源检测）：

```bash
    if [[ "$fb_code" =~ ^(200|401|403|404|301|302)$ ]]; then
```

改为：

```bash
    if [[ "$fb_code" =~ $HTTP_OK_CODES ]]; then
```

（同样，若 shellcheck 报错则保持原样。）

### Step 6: 验证

- [ ] **Step 6a: 语法检查**

Run: `bash -n install-docker.sh`
Expected: 无输出。

- [ ] **Step 6b: 确认无重复的 reduce 循环**

Run: `grep -n 'for f in "\$tmpdir"/\*' install-docker.sh`
Expected: 仅 `reduce_probe_results` 函数内 1 处匹配。probe_pkg/probe_docker 内不应再有。

- [ ] **Step 6c: 功能验证 --help**

Run: `bash install-docker.sh --help`
Expected: 打印帮助，退出码 0。

- [ ] **Step 7: Commit**

```bash
git add install-docker.sh
git commit -m "refactor(install-docker): extract reduce_probe_results helper

probe_pkg_mirrors (L231-242) and probe_docker_mirrors (L294-305) had
byte-for-byte identical reduce loops (~12 lines each). Extracted into
reduce_probe_results helper that both functions now share.

probe_docker_mirrors keeps its fallback-source logic: when reduce
returns empty, it falls through to the DOCKER_FALLBACK_MIRRORS branch.

Also added HTTP_OK_CODES constant for the duplicated status-code
regex, if shellcheck permits (otherwise keeps literal)."
```

---

## Task 4: P1-3 抽 Oracle/rpm 共享 helper + install_docker_ol 独立

**Files:**
- Modify: `install-docker.sh`

**背景**：`install_docker_rpm`（L389-422）和 `install_docker` 的 `ol)` 分支（L451-467）重复了：repo-guard+backup 惯用法、fallback install 链。抽两个共享 helper，并把 Oracle 分支独立为 `install_docker_ol`。

### Step 1: 定义 ensure_rpm_repo_file helper

- [ ] **Step 1a: 在 reduce_probe_results 之后插入**

找到 reduce_probe_results 函数定义后的空行，在模块 5 注释之前插入：

```bash
# --- RPM repo 文件管理 (已存在则跳过，否则备份+创建) ---
# 参数: $1 = repo 文件路径; 剩余参数 = 创建命令 (已存在时跳过，否则执行 $@)
ensure_rpm_repo_file() {
  local repo_file="$1"; shift
  if [[ -f "$repo_file" ]] && grep -q "docker-ce" "$repo_file" 2>/dev/null; then
    log_info "📦 Docker repo 已存在，跳过创建"
    return 0
  fi
  [[ -f "$repo_file" ]] && cp -f "$repo_file" "${repo_file}.bak.$(date +%s)" 2>/dev/null || true
  "$@"
}
```

### Step 2: 定义 install_docker_pkgs_fallback helper

- [ ] **Step 2a: 紧接 ensure_rpm_repo_file 之后插入**

```bash
# --- Docker 包两步安装 (全套 --nobest 失败则降级最小集) ---
# 参数: $1 = 包管理器 (yum/dnf)
install_docker_pkgs_fallback() {
  local pkg_mgr="$1"
  run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin --nobest || \
  run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io
}
```

### Step 3: 用 helper 重构 install_docker_rpm

- [ ] **Step 3a: 替换 repo-guard + heredoc 块**

找到 `install_docker_rpm` 内（原 L403-415）：

```bash
  if [[ -f "$repo_file" ]] && grep -q "docker-ce" "$repo_file" 2>/dev/null; then
    log_info "📦 Docker repo 已存在，跳过创建"
  else
    [[ -f "$repo_file" ]] && cp -f "$repo_file" "${repo_file}.bak.$(date +%s)" 2>/dev/null || true
    cat > "$repo_file" <<EOF
[docker-ce-stable]
name=Docker CE Stable
baseurl=${target_repo_url}/${base_ver}/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=${repo_gpg}/centos/gpg
EOF
  fi
```

替换为：

```bash
  ensure_rpm_repo_file "$repo_file" cat \> "$repo_file" <<EOF
[docker-ce-stable]
name=Docker CE Stable
baseurl=${target_repo_url}/${base_ver}/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=${repo_gpg}/centos/gpg
EOF
```

**注意**：heredoc 作为 `ensure_rpm_repo_file` 的参数传递——`cat > "$repo_file" <<EOF ... EOF` 整体是 `$@`。这在 bash 里可行：函数内 `"$@"` 会执行这个重定向+heredoc。**需测试验证**。

**若 heredoc 传参失败**（bash 对函数参数中的 heredoc 支持有限），改用回调形式：`ensure_rpm_repo_file "$repo_file" create_rpm_repo_file`，其中 `create_rpm_repo_file` 是单独定义的函数。**实现时先试 heredoc 直传，失败则改回调。**

- [ ] **Step 3b: 替换 fallback install 链**

找到（原 L420-421，Task 2 已改为 run_install）：

```bash
  run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest || \
  run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io
```

替换为：

```bash
  install_docker_pkgs_fallback "$pkg_mgr"
```

### Step 4: 新增 install_docker_ol 函数

- [ ] **Step 4a: 在 install_docker_rpm 之后插入**

找到 `install_docker_rpm` 函数结束的 `}`（原 L422），在其后插入：

```bash
# --- Oracle Linux ---
install_docker_ol() {
  if ! command -v dnf &>/dev/null; then
    log_error "❌ Oracle Linux 需要 dnf，但未找到"
    return 1
  fi
  run_install dnf install -y dnf-plugins-core || true

  local docker_repo="/etc/yum.repos.d/docker-ce.repo"
  ensure_rpm_repo_file "$docker_repo" \
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo \
    || { log_error "❌ 添加 Docker 仓库失败"; return 1; }

  install_docker_pkgs_fallback dnf
}
```

### Step 5: 简化 install_docker 的 ol) 分支

- [ ] **Step 5a: 替换 ol) 内联代码为函数调用**

找到 `install_docker` 的 case 中 `ol)` 分支（原 L451-467）：

```bash
    ol)
      if ! command -v dnf &>/dev/null; then
        log_error "❌ Oracle Linux 需要 dnf，但未找到"
        return 1
      fi
      dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
      local docker_repo="/etc/yum.repos.d/docker-ce.repo"
      if [[ -f "$docker_repo" ]] && grep -q "docker-ce" "$docker_repo" 2>/dev/null; then
        log_info "📦 Docker repo 已存在，跳过创建"
      else
        [[ -f "$docker_repo" ]] && cp -f "$docker_repo" "${docker_repo}.bak.$(date +%s)" 2>/dev/null || true
        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1 || \
          { log_error "❌ 添加 Docker 仓库失败"; return 1; }
      fi
      dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest >/dev/null 2>&1 || \
      dnf install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1
      ;;
```

替换为：

```bash
    ol)
      install_docker_ol
      ;;
```

### Step 6: 验证

- [ ] **Step 6a: 语法检查**

Run: `bash -n install-docker.sh`
Expected: 无输出。

- [ ] **Step 6b: 确认 ol) 分支已精简**

Run: `grep -A2 'ol)' install-docker.sh`
Expected: 看到 `ol)` 后只有 `install_docker_ol` 一行 + `;;`。

- [ ] **Step 6c: 确认 install_docker_ol 存在且用 helper**

Run: `grep -n 'install_docker_ol\|ensure_rpm_repo_file\|install_docker_pkgs_fallback' install-docker.sh`
Expected: 三个函数都有定义和调用。

- [ ] **Step 6d: 功能验证 --help**

Run: `bash install-docker.sh --help`
Expected: 打印帮助，退出码 0。

- [ ] **Step 6e: heredoc 传参测试（关键）**

这一步验证 `ensure_rpm_repo_file "$repo_file" cat > "$repo_file" <<EOF ... EOF` 是否能正确执行 heredoc。Run:

```bash
bash -c '
ensure_rpm_repo_file() {
  local repo_file="$1"; shift
  if [[ -f "$repo_file" ]] && grep -q "docker-ce" "$repo_file" 2>/dev/null; then
    echo "SKIP"; return 0
  fi
  [[ -f "$repo_file" ]] && cp -f "$repo_file" "${repo_file}.bak.$(date +%s)" 2>/dev/null || true
  "$@"
}
tmp=$(mktemp)
ensure_rpm_repo_file "$tmp" cat > "$tmp" <<EOF
[docker-ce-stable]
name=Docker CE Stable
EOF
cat "$tmp"
rm -f "$tmp"
'
```

Expected: 打印 `[docker-ce-stable]` 和 `name=Docker CE Stable` 两行。**若输出为空或报错**，说明 heredoc 传参失败，需改用回调形式（见 Step 3a 注）。

- [ ] **Step 7: Commit**

```bash
git add install-docker.sh
git commit -m "refactor(install-docker): extract Oracle/rpm shared helpers

install_docker_rpm and the inline ol) branch in install_docker duplicated:
- repo-file guard + timestamped backup idiom
- full-to-minimal fallback install chain

Extracted: ensure_rpm_repo_file (guard+backup+delegate) and
install_docker_pkgs_fallback (full --nobest, then minimal).

New install_docker_ol function mirrors install_docker_rpm, using
dnf config-manager --add-repo (Oracle-specific repo creation, NOT
shared with rpm heredoc path). install_docker case ol) now one line."
```

---

## Task 5: P1-1 daemon.json 追加+去重（行为变更）

**Files:**
- Modify: `install-docker.sh`

**背景**：L561 `cfg['registry-mirrors'] = [url]` 覆盖整个数组，丢弃用户既有配置。改为追加+去重，上限 MAX_MIRRORS=3。

### Step 1: 加 MAX_MIRRORS 常量

- [ ] **Step 1a: 在 HTTP_OK_CODES 之后（Task 3 加的）追加**

找到：

```bash
readonly HTTP_OK_CODES='^(200|401|403|404|301|302)$'
```

在其后加：

```bash
readonly MAX_MIRRORS=3
```

### Step 2: 改 python3 路径（L561）

- [ ] **Step 2a: 替换覆盖逻辑为追加去重**

找到 `safe_update_daemon_json` 的 python3 块（原 L553-565）：

```python
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, os, sys
path, url = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        try: cfg = json.load(f)
        except: pass
cfg['registry-mirrors'] = [url]
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$conf" "$new_url" && return 0
  fi
```

替换为：

```python
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, os, sys
path, url, max_mirrors = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        try: cfg = json.load(f)
        except: pass
existing = cfg.get('registry-mirrors', [])
merged = [url] + [m for m in existing if m != url]
cfg['registry-mirrors'] = merged[:max_mirrors]
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$conf" "$new_url" "$MAX_MIRRORS" && return 0
  fi
```

### Step 3: 改 jq 路径（L568-570）

- [ ] **Step 3a: 替换覆盖逻辑为追加去重**

找到：

```bash
  if command -v jq &>/dev/null; then
    jq --arg url "$new_url" '.["registry-mirrors"] = [$url]' "$conf" > "${conf}.tmp" 2>/dev/null && \
    mv "${conf}.tmp" "$conf" && return 0
  fi
```

替换为：

```bash
  if command -v jq &>/dev/null; then
    jq --arg url "$new_url" --argjson max "$MAX_MIRRORS" \
      '.["registry-mirrors"] = ([$url] + (.["registry-mirrors"] // [] | map(select(. != $url))))[:$max]' \
      "$conf" > "${conf}.tmp" 2>/dev/null && \
    mv "${conf}.tmp" "$conf" && return 0
  fi
```

### Step 4: 改 sed 降级路径注释（L573）

- [ ] **Step 4a: 更新注释说明限制**

找到：

```bash
  # sed 最终降级：仅改 registry-mirrors，不碰其他字段
```

改为：

```bash
  # sed 最终降级：不支持追加去重，仅写入单源（覆盖既有 registry-mirrors）
  # 如需保留多源，请安装 python3 或 jq。
```

（sed 实现不变——保持现有的覆盖单源逻辑。）

### Step 5: 验证

- [ ] **Step 5a: 语法检查**

Run: `bash -n install-docker.sh`
Expected: 无输出。

- [ ] **Step 5b: daemon.json 追加测试（python3 路径）**

Run:

```bash
tmp=$(mktemp)
printf '{"registry-mirrors": ["https://old1.example.com", "https://old2.example.com"], "log-level": "info"}' > "$tmp"
# 模拟调用 python3 逻辑（提取出来测）
python3 -c "
import json, os, sys
path, url, max_mirrors = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        try: cfg = json.load(f)
        except: pass
existing = cfg.get('registry-mirrors', [])
merged = [url] + [m for m in existing if m != url]
cfg['registry-mirrors'] = merged[:max_mirrors]
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$tmp" "https://new.example.com" 3
cat "$tmp"
rm -f "$tmp"
```

Expected: 输出 JSON，`registry-mirrors` = `["https://new.example.com", "https://old1.example.com", "https://old2.example.com"]`（新源在头部，旧的保留），`log-level` 保留。

- [ ] **Step 5c: 去重测试**

Run:

```bash
tmp=$(mktemp)
printf '{"registry-mirrors": ["https://dup.example.com"]}' > "$tmp"
python3 -c "
import json, os, sys
path, url, max_mirrors = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        try: cfg = json.load(f)
        except: pass
existing = cfg.get('registry-mirrors', [])
merged = [url] + [m for m in existing if m != url]
cfg['registry-mirrors'] = merged[:max_mirrors]
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$tmp" "https://dup.example.com" 3
cat "$tmp"
rm -f "$tmp"
```

Expected: `registry-mirrors` = `["https://dup.example.com"]`（去重，无重复）。

- [ ] **Step 5d: 上限测试**

构造 5 个旧源 + 1 个新源，验证截断为 3 个。Run:

```bash
tmp=$(mktemp)
printf '{"registry-mirrors": ["a","b","c","d","e"]}' > "$tmp"
python3 -c "
import json, os, sys
path, url, max_mirrors = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        try: cfg = json.load(f)
        except: pass
existing = cfg.get('registry-mirrors', [])
merged = [url] + [m for m in existing if m != url]
cfg['registry-mirrors'] = merged[:max_mirrors]
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$tmp" "new" 3
cat "$tmp"
rm -f "$tmp"
```

Expected: `registry-mirrors` = `["new", "a", "b"]`（新源头部 + 前 2 个旧的，总数 3）。

- [ ] **Step 6: Commit**

```bash
git add install-docker.sh
git commit -m "fix(install-docker): daemon.json mirror append+dedupe instead of overwrite

BEHAVIOR CHANGE: safe_update_daemon_json previously did
cfg['registry-mirrors'] = [url] — overwriting the entire array and
discarding user-configured mirrors. Now: new mirror inserted at head
(best first), deduped against existing, capped at MAX_MIRRORS=3.

Affects python3 and jq paths. sed fallback keeps single-overwrite
(noted in comment) since complex JSON append isn't feasible in sed.

auto_configure_mirror idempotency (grep -qxF) unaffected: if new URL
already in array, skip write entirely."
```

---

## Task 6: P0-1 补 CI lint + 修 shellcheck 报错

**Files:**
- Modify: `.github/workflows/ocserv.yml`
- Modify: `docs/project-architecture.md`
- Modify: `install-docker.sh`（修 shellcheck 报错）
- Modify: `scripts/occ`（修 shellcheck 报错）

### Step 1: 本地先跑 shellcheck 看报错

- [ ] **Step 1a: 安装 shellcheck（若未装）**

Run: `command -v shellcheck >/dev/null 2>&1 && shellcheck --version | head -1 || echo "NEED_INSTALL"`

若输出 NEED_INSTALL，用 brew 安装（macOS）：`brew install shellcheck`

- [ ] **Step 1b: 跑 shellcheck 看 install-docker.sh 报错**

Run: `shellcheck -s bash install-docker.sh 2>&1 | head -60`

记录所有 SC 编号和行号。常见预期：SC2155（`local x=$(cmd)` 掩码退出码）、SC2086（未引用变量）、SC2034（未用变量）。

- [ ] **Step 1c: 跑 shellcheck 看 scripts/occ 报错**

Run: `shellcheck -s bash scripts/occ 2>&1 | head -40`

### Step 2: 修 install-docker.sh 的 shellcheck 报错

- [ ] **Step 2a: 逐条修 SC2155（local x=$(cmd) 掩码退出码）**

对每个 SC2155 报错的行，把：

```bash
local x=$(cmd)
```

改为：

```bash
local x
x=$(cmd)
```

**已知高频位置**（需根据 Step 1b 实际输出确认行号）：
- L116 `metrics=$(...)` → 已是分离的（`local metrics` 在 L115，赋值在 L116），检查是否报
- L368 `arch=$(...)` → 分离
- 实际报错行号以 Step 1b 输出为准

- [ ] **Step 2b: 修 SC2086（未引用变量）**

对每个 SC2086 报错的变量加引号。**例外**：`$pkg_mgr`（包管理器命令名）在 `run_install "$pkg_mgr" install ...` 中已通过 Task 2 的改造加了引号。检查是否还有遗漏。

**已知可能报**：`grep -o 'time=[0-9.]*'`（L209）等——这些若报 SC2086 但语义安全，加 `# shellcheck disable=SC2086` 注释。

- [ ] **Step 2c: 修 SC2034（未用变量）**

检查是否有声明但未用的变量。若 `DH_CFG_STATUS` 等状态变量报 SC2034，加 `# shellcheck disable=SC2034`（它们是跨函数通信的全局状态，设计如此）。

- [ ] **Step 2d: 重跑 shellcheck 确认**

Run: `shellcheck -s bash install-docker.sh`
Expected: 无输出（或仅 SC2312，由 .shellcheckrc 在 Task 7 抑制）。若仍有报错，继续修。

### Step 3: 修 scripts/occ 的 shellcheck 报错

- [ ] **Step 3a: 按 Step 1c 输出逐条修**

同 Step 2 方法论：SC2155 分离声明、SC2086 加引号、合理误报加 disable 注释。

- [ ] **Step 3b: 重跑 shellcheck 确认**

Run: `shellcheck -s bash scripts/occ`
Expected: 无输出。

### Step 4: 加 CI lint 到 ocserv.yml

- [ ] **Step 4a: 在 Check shell syntax step 追加 bash 类**

找到 `.github/workflows/ocserv.yml` L40-47：

```yaml
      - name: Check shell syntax
        run: |
          sh -n scripts/configure-alpine-repositories.sh
          sh -n scripts/common.sh
          sh -n scripts/prepare-ocserv-config.sh
          sh -n scripts/render-ocserv-conf.sh
          sh -n docker/ocserv/init.sh
          sh -n docker/ocserv/entrypoint.sh
```

改为（追加 bash 类两行）：

```yaml
      - name: Check shell syntax
        run: |
          sh -n scripts/configure-alpine-repositories.sh
          sh -n scripts/common.sh
          sh -n scripts/prepare-ocserv-config.sh
          sh -n scripts/render-ocserv-conf.sh
          sh -n docker/ocserv/init.sh
          sh -n docker/ocserv/entrypoint.sh
          bash -n install-docker.sh
          bash -n scripts/occ
```

- [ ] **Step 4b: 在 Lint shell scripts step 追加 bash 类**

找到 L49-56：

```yaml
      - name: Lint shell scripts
        run: |
          shellcheck -s sh scripts/configure-alpine-repositories.sh
          shellcheck -s sh scripts/common.sh
          shellcheck -s sh scripts/prepare-ocserv-config.sh
          shellcheck -s sh scripts/render-ocserv-conf.sh
          shellcheck -s sh docker/ocserv/init.sh
          shellcheck -s sh docker/ocserv/entrypoint.sh
```

改为：

```yaml
      - name: Lint shell scripts
        run: |
          shellcheck -s sh scripts/configure-alpine-repositories.sh
          shellcheck -s sh scripts/common.sh
          shellcheck -s sh scripts/prepare-ocserv-config.sh
          shellcheck -s sh scripts/render-ocserv-conf.sh
          shellcheck -s sh docker/ocserv/init.sh
          shellcheck -s sh docker/ocserv/entrypoint.sh
          shellcheck -s bash install-docker.sh
          shellcheck -s bash scripts/occ
```

### Step 5: 修 docs/project-architecture.md §五 虚假声明

- [ ] **Step 5a: 更新脚本分类描述**

找到 `docs/project-architecture.md` L286-288（§五 Shell 脚本风格）：

```
仓库 shell 脚本按解释器能力明确分组：

- 纯 POSIX 脚本使用 `#!/bin/sh` 和 `set -eu`，并在 CI 中通过 `sh -n` 检查；运行期入口、配置渲染脚本都归入这一类。
- 需要 Bash 特性的脚本使用 `#!/usr/bin/env bash` 和 `set -euo pipefail`，并在 CI 中通过 `bash -n` 检查；当前 `install-docker.sh` 和 `scripts/occ` 归入这一类。
- 新增 `.sh` 文件必须先选择上述一类，并同步更新静态测试中的脚本分类表。
```

改为（补充 shellcheck 声明，与实际一致）：

```
仓库 shell 脚本按解释器能力明确分组：

- 纯 POSIX 脚本使用 `#!/bin/sh` 和 `set -eu`，在 CI 中通过 `sh -n` 语法检查和 `shellcheck -s sh` 静态检查；运行期入口、配置渲染脚本都归入这一类。
- 需要 Bash 特性的脚本使用 `#!/usr/bin/env bash` 和 `set -euo pipefail`，在 CI 中通过 `bash -n` 语法检查和 `shellcheck -s bash` 静态检查；当前 `install-docker.sh` 和 `scripts/occ` 归入这一类。
- 新增 `.sh` 文件必须先选择上述一类，并同步更新静态测试中的脚本分类表。
```

### Step 6: 验证

- [ ] **Step 6a: 本地完整 lint**

Run:
```bash
bash -n install-docker.sh && bash -n scripts/occ && \
shellcheck -s bash install-docker.sh && shellcheck -s bash scripts/occ && \
echo "ALL PASS"
```
Expected: 输出 `ALL PASS`。

- [ ] **Step 6b: workflow YAML 语法验证**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ocserv.yml'))" && echo "YAML OK"`
Expected: 输出 `YAML OK`。

- [ ] **Step 7: Commit**

```bash
git add install-docker.sh scripts/occ .github/workflows/ocserv.yml docs/project-architecture.md
git commit -m "ci: lint install-docker.sh and scripts/occ in CI

install-docker.sh (749 lines) and scripts/occ had ZERO CI lint coverage
despite docs/project-architecture.md claiming otherwise. Added:
- bash -n syntax check for both files
- shellcheck -s bash static check for both files

Fixed shellcheck findings: SC2155 (separate local decl from assign),
SC2086 (quote variables), with disable comments for safe-intent cases.

Updated §五 of project-architecture.md: added shellcheck to the
description so it now matches CI reality."
```

---

## Task 7: P2-2 补 .shellcheckrc

**Files:**
- Create: `.shellcheckrc`

- [ ] **Step 1: 创建 .shellcheckrc**

写入文件 `.shellcheckrc`：

```ini
disable=SC2312
```

（SC2312 是"Consider invoking this command separately to mitigate fork bombs"——对 `run_install "$@"` 的函数委派模式有误报。）

- [ ] **Step 2: 验证 shellcheck 读取配置**

Run: `shellcheck -s bash install-docker.sh`
Expected: SC2312 相关报错（若有）被抑制。

- [ ] **Step 3: Commit**

```bash
git add .shellcheckrc
git commit -m "chore: add .shellcheckrc to disable SC2312

SC2312 flags function delegation patterns like run_install \"\$@\" as
potential fork-bomb risks — a false positive for our controlled helper."
```

---

## Task 8: P2-1 exit→return 统一

**Files:**
- Modify: `install-docker.sh`

### Step 1: 改 check_prerequisites

- [ ] **Step 1a: 把 exit 1 改为 return 1**

找到 `check_prerequisites`（原 L105-109）：

```bash
check_prerequisites() {
  [[ $EUID -ne 0 ]] && { log_error "请使用 root 用户或 sudo 执行此脚本"; exit 1; }
  command -v curl &>/dev/null || { log_error "未找到 curl，请先安装"; exit 1; }
  TMPDIR_BASE=$(mktemp -d) || { log_error "无法创建临时目录"; exit 1; }
}
```

改为：

```bash
check_prerequisites() {
  [[ $EUID -ne 0 ]] && { log_error "请使用 root 用户或 sudo 执行此脚本"; return 1; }
  command -v curl &>/dev/null || { log_error "未找到 curl，请先安装"; return 1; }
  TMPDIR_BASE=$(mktemp -d) || { log_error "无法创建临时目录"; return 1; }
}
```

### Step 2: 在 main 里加错误传播

- [ ] **Step 2a: 找到 main 的 check_prerequisites 调用**

找到 `main` 函数内（原 L727）：

```bash
  parse_args "$@"
  check_prerequisites
  init_os_vars
```

改为：

```bash
  parse_args "$@"
  check_prerequisites || exit 1
  init_os_vars || exit 1
```

### Step 3: 验证

- [ ] **Step 3a: 语法检查**

Run: `bash -n install-docker.sh`
Expected: 无输出。

- [ ] **Step 3b: 非 root 运行测试（验证 return 而非 exit）**

Run: `bash install-docker.sh --help` (以非 root)
Expected: --help 在 parse_args 就 exit 0，不触发 check_prerequisites。

Run（模拟失败传播）: `id -u` 确认非 root，然后 `bash install-docker.sh 2>&1; echo "EXIT: $?"`
Expected: 打印 root 错误 + 退出码 1。

- [ ] **Step 4: Commit**

```bash
git add install-docker.sh
git commit -m "refactor(install-docker): exit 1 to return 1 in leaf functions

check_prerequisites used exit 1 directly, bypassing caller control
and making it untestable as a unit. Changed to return 1; main now
propagates via '|| exit 1'.

parse_args keeps exit for -h/--help and unknown args (CLI contract).
install_docker's *) arm already uses return 1."
```

---

## Task 9: P2-4 --debug 模式

**Files:**
- Modify: `install-docker.sh`

### Step 1: parse_args 加 --debug

- [ ] **Step 1a: 加 case 分支**

找到 `parse_args` 的 case（原 L81-99），在 `--skip-cloud)` 之后加：

```bash
      --debug)         DEBUG=true; shift ;;
```

完整片段（在 `-y|--yes)` 之前插入）：

```bash
      --skip-cloud)     SKIP_CLOUD=true; shift ;;
      --debug)          DEBUG=true; shift ;;
      -y|--yes)         YES_MODE=true; shift ;;
```

### Step 2: 更新 --help 文本

- [ ] **Step 2a: 加 --debug 说明**

找到帮助文本（原 L87-95）：

```
用法: $0 [选项]
选项:
  --no-mirror    跳过镜像加速配置
  --force        强制重新安装 Docker
  --skip-cloud   跳过云厂商检测
  -y, --yes      非交互模式（自动确认所有提示，适合 CI/CD）
  -h, --help     显示帮助
```

改为：

```
用法: $0 [选项]
选项:
  --no-mirror    跳过镜像加速配置
  --force        强制重新安装 Docker
  --skip-cloud   跳过云厂商检测
  --debug        显示安装命令的完整输出（调试用）
  -y, --yes      非交互模式（自动确认所有提示，适合 CI/CD）
  -h, --help     显示帮助
```

### Step 3: 验证

- [ ] **Step 3a: 语法检查**

Run: `bash -n install-docker.sh`
Expected: 无输出。

- [ ] **Step 3b: --help 显示新选项**

Run: `bash install-docker.sh --help 2>&1 | grep debug`
Expected: 输出含 `--debug` 的行。

- [ ] **Step 3c: --debug 设标志验证**

Run: `bash -c 'DEBUG=false; source <(sed -n "/^parse_args/,/^}/p" install-docker.sh); parse_args --debug; echo "DEBUG=$DEBUG"'`
（若 source 失败，改为直接 `bash install-docker.sh --debug --help` 确认不报未知参数错误。）
Expected: `DEBUG=true`。

- [ ] **Step 4: Commit**

```bash
git add install-docker.sh
git commit -m "feat(install-docker): add --debug flag for verbose install output

--debug sets DEBUG=true, which run_install checks to decide whether
to silence install command output (default) or show it (debug).

Useful for diagnosing apt/dnf failures that are otherwise swallowed."
```

---

## Task 10: P2-3 + P2-5 validate_args 框架 + Debian codename 改进

**Files:**
- Modify: `install-docker.sh`

### Step 1: 加 validate_args 框架（P2-3）

- [ ] **Step 1a: 在 parse_args 之后插入 validate_args**

找到 `parse_args` 函数结束的 `}`（原 L100），在其后插入：

```bash
# 参数组合校验。当前无互斥约束；新增 flag 时在此校验。
validate_args() {
  :
}
```

### Step 2: 在 main 调用 validate_args

- [ ] **Step 2a: main 里 parse_args 之后加调用**

找到（Task 8 已改为）：

```bash
  parse_args "$@"
  check_prerequisites || exit 1
```

改为：

```bash
  parse_args "$@"
  validate_args
  check_prerequisites || exit 1
```

### Step 3: 改 Debian codename 兜底（P2-5）

- [ ] **Step 3a: 重写 codename 获取逻辑**

找到 `install_docker_apt` 内（原 L370-380）：

```bash
  # shellcheck source=/etc/os-release
  codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-stable}")
  # Debian 老版本可能没有 VERSION_CODENAME，用 codename 映射兜底
  if [[ "$codename" == "stable" && "$OS_TYPE" == "debian" ]]; then
    local debian_ver="${VERSION_ID%%.*}"
    case "$debian_ver" in
      11) codename="bullseye" ;;
      12) codename="bookworm" ;;
      13) codename="trixie" ;;
      *)  codename="bookworm" ;;
    esac
  fi
```

改为（优先信 VERSION_CODENAME，仅空/stable 时查映射表）：

```bash
  # shellcheck source=/etc/os-release
  codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
  # VERSION_CODENAME 为空或 "stable" 时，用版本号映射兜底（老版本 Debian）
  if [[ -z "$codename" || "$codename" == "stable" ]]; then
    local debian_ver="${VERSION_ID%%.*}"
    case "$debian_ver" in
      11) codename="bullseye" ;;
      12) codename="bookworm" ;;
      13) codename="trixie" ;;
      *)  codename="bookworm" ;;
    esac
  fi
```

### Step 4: 验证

- [ ] **Step 4a: 语法检查**

Run: `bash -n install-docker.sh`
Expected: 无输出。

- [ ] **Step 4b: shellcheck**

Run: `shellcheck -s bash install-docker.sh`
Expected: 无输出。

- [ ] **Step 4c: 功能验证 --help**

Run: `bash install-docker.sh --help`
Expected: 打印帮助，退出码 0。

- [ ] **Step 5: Commit**

```bash
git add install-docker.sh
git commit -m "refactor(install-docker): validate_args hook + Debian codename fallback

P2-3: Add validate_args() empty framework (no current mutex constraints;
placeholder for future flag-combination validation).

P2-5: Debian codename detection now trusts VERSION_CODENAME first
(modern Debian always sets it), only consulting the 11/12/13 mapping
table when VERSION_CODENAME is empty or literally 'stable'. Prevents
silent mis-targeting on future Debian releases."
```

---

## Task 11: 最终验证 + PR

### Step 1: 全量本地验证

- [ ] **Step 1a: 完整 lint**

Run:
```bash
bash -n install-docker.sh && bash -n scripts/occ && \
shellcheck -s bash install-docker.sh && shellcheck -s bash scripts/occ && \
echo "LINT ALL PASS"
```
Expected: `LINT ALL PASS`。

- [ ] **Step 1b: standalone 验证**

Run: `bash install-docker.sh --help`
Expected: 帮助文本含所有 flag（--no-mirror/--force/--skip-cloud/--debug/-y/-h），退出码 0。

- [ ] **Step 1c: YAML 验证**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ocserv.yml')); print('YAML OK')"`
Expected: `YAML OK`。

- [ ] **Step 1d: 确认改动文件清单**

Run: `git diff --stat main`
Expected: 列出 install-docker.sh、scripts/occ、.github/workflows/ocserv.yml、docs/project-architecture.md、.shellcheckrc、docs/superpowers/specs/*、docs/superpowers/plans/*。

### Step 2: 推送 + 开 PR

- [ ] **Step 2a: 推送分支**

Run: `git push -u origin refactor/install-docker-cleanup`

- [ ] **Step 2b: 开 PR**

Run:
```bash
gh pr create \
  --title "refactor: install-docker.sh bounded cleanup (P0+P1+P2)" \
  --body "## Summary

Bounded cleanup of install-docker.sh based on three-source comparison
(Coder install.sh benchmark + project conventions + current code).
No large-scale rewrite — skeleton was healthy, recent refactors on track.

## Changes

**P0 (safety + compliance):**
- Add CI lint (bash -n + shellcheck) for install-docker.sh and scripts/occ
- Fix 6 bare silent-install commands via run_install helper (error visibility)
- Fix docs/project-architecture.md false CI claim

**P1 (correctness + maintainability):**
- daemon.json: append+dedupe (was overwrite, discarding user mirrors). MAX_MIRRORS=3
- Extract reduce_probe_results (eliminate byte-identical reduce loops)
- Extract ensure_rpm_repo_file + install_docker_pkgs_fallback; new install_docker_ol
- Remove dead source common.sh (0 references)

**P2 (polish):**
- exit→return in leaf functions; validate_args() hook
- .shellcheckrc; --debug flag; Debian codename trusts VERSION_CODENAME first

## Behavior change

daemon.json registry-mirrors: previously overwrote entire array with single
new mirror. Now: inserts new at head, dedupes, caps at 3. User-configured
mirrors are preserved.

## Test plan
- [x] bash -n + shellcheck pass locally
- [x] bash install-docker.sh --help works standalone (no common.sh dep)
- [x] daemon.json append/dedupe/cap tested (python3 path)
- [ ] CI green on this PR" \
  --base main
```

- [ ] **Step 3: 观察 CI 结果**

推送后等待 CI 运行。若 validate job 失败，根据报错修复。若通过，PR 可 review。

---

## Self-Review

**Spec coverage:**
- P0-1 CI lint → Task 6 ✅
- P0-2 run_install → Task 2 ✅
- P1-1 daemon.json → Task 5 ✅
- P1-2 probe reduce → Task 3 ✅
- P1-3 Oracle → Task 4 ✅
- P1-4 删 source → Task 1 ✅
- P2-1 exit→return → Task 8 ✅
- P2-2 .shellcheckrc → Task 7 ✅
- P2-3 validate_args → Task 10 ✅
- P2-4 --debug → Task 9 ✅
- P2-5 Debian codename → Task 10 ✅

**Placeholder scan:** 无 TBD/TODO。shellcheck 报错的具体行号标注为"以实际输出为准"——这是因为无法预判 shellcheck 版本的具体报告，实现时跑一次即可获得，不算 placeholder。

**Type consistency:** `run_install`、`reduce_probe_results`、`ensure_rpm_repo_file`、`install_docker_pkgs_fallback`、`install_docker_ol`、`validate_args` 在所有 Task 中签名一致。

**Spec 偏差（已在文首说明）:** 不修改 source-cache.yml 的 paths:（install-docker.sh 非 Docker 镜像构建链）。

---

## 执行顺序总览

```
Task 1 (P1-4 删 source)          ── 独立，最小
Task 2 (P0-2 run_install)        ── Task 4/5 依赖
Task 3 (P1-2 probe reduce)       ── 独立
Task 4 (P1-3 Oracle helper)      ── 依赖 Task 2
Task 5 (P1-1 daemon.json)        ── 独立
Task 6 (P0-1 CI lint)            ── 最后做（lint 所有前面改动）
Task 7 (P2-2 .shellcheckrc)      ── Task 6 之后
Task 8 (P2-1 exit→return)        ── 独立
Task 9 (P2-4 --debug)            ── 依赖 Task 2 (DEBUG 变量)
Task 10 (P2-3+P2-5)              ── 独立
Task 11 (最终验证 + PR)           ── 全部完成后
```
