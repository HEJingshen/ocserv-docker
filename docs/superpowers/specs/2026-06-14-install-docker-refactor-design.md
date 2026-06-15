# install-docker.sh 重构设计

> 日期：2026-06-14
> 状态：Draft（待 review）
> 来源：三源对比分析（Coder `install.sh` 业界标杆 + 项目规范条例 + 现状代码）
> 范围：`install-docker.sh` + 关联 CI/文档

## 一、背景与动机

对 `install-docker.sh`（v3.1，749 行，22 函数，8 模块）做了三源深度对比分析：

1. **Coder `install.sh`**（业界标杆）：POSIX sh、`sudo_sh_c` 抽象、`DRY_RUN`、打印+执行分离、极简分发。
2. **本项目规范条例**（`docs/project-architecture.md` §四/§五）：POSIX/Bash 二分、CI `sh -n`+`bash -n` 检查、幂等、`set -e` 安全、并发≤8。
3. **现状代码**：领域复杂度高（镜像探测+daemon.json+云检测），骨架健康，但有若干有界技术债。

**核心判断**：不需要大规模（架构级）重构。最近两次 refactor（`0a99bc8` 抽 helper、`0c15887` 抽 validator）方向正确。本次聚焦还掉 **2 个 P0 + 4 个 P1 + 5 个 P2** 的有界技术债。

**定位差异**：本项目装的是 Docker 引擎本身，多了中国网络环境特化（镜像探测、加速配置、云厂商检测），这些是 Coder 没有的领域价值，不能照搬 Coder 范式。但 Coder 的工程纪律（错误可见性、命令执行抽象）值得借鉴。

## 二、范围（Scope）

### 做什么

| 优先级 | 项 | phase | 一句话 |
|--------|-----|-------|--------|
| P0-1 | 补 CI lint | 1（必做） | install-docker.sh + occ 进 CI 的 `bash -n` + `shellcheck`；修文档虚假声明 |
| P0-2 | 修错误可见性 | 1（必做） | 引入 `run_install` helper，统一安装命令执行，失败可见 |
| P1-1 | daemon.json 追加去重 | 1（必做） | `registry-mirrors` 从覆盖改为追加+去重，上限 3 |
| P1-2 | probe reduce 去重 | 1（必做） | 抽 `reduce_probe_results` helper，消除逐字重复 |
| P1-3 | Oracle 分支独立 | 1（必做） | 抽 `install_docker_ol` + 共享 helper |
| P1-4 | 删死依赖 | 1（必做） | 删 `source common.sh`（0 引用） |
| P2-1 | exit→return 统一 | 2（选做） | 叶子函数 `exit 1` → `return 1` |
| P2-2 | 补 .shellcheckrc | 2（选做） | 固化项目级 shellcheck 策略 |
| P2-3 | parse_args 组合校验 | 2（选做） | 加 `validate_args()` 框架 |
| P2-4 | --debug 模式 | 2（选做） | `run_install` 配合 DEBUG 切换可见性 |
| P2-5 | Debian codename 兜底改进 | 2（选做） | 优先信任 VERSION_CODENAME |

### 不做什么（Non-Goals）

- ❌ **不迁移到 POSIX sh**：重度依赖 bash 特性（`declare -A`、`BASH_VERSINFO`、`wait -n`、`[[ =~ ]]`），迁移成本 > 收益。
- ❌ **不统一全仓日志方言**：三种方言（`log_*`+emoji / `die()` / `fail()`）各有适用场景。
- ❌ **不引入 Coder 式 `sudo_sh_c` 抽象**：本项目无 DRY_RUN 需求，bash 语义下收益有限。
- ❌ **不引入 DRY_RUN 模式**：语义边界复杂，YAGNI。
- ❌ **不动 `detect_cloud` 的 DMI 兜底**：虽在云上几乎不可达，但作为最后防线有保留价值，零风险。

### 核心约束

- `install-docker.sh` 必须保持 **standalone 可独立下载运行**（`curl | bash` 场景），任何改动不得引入对仓库内其他文件的硬依赖。
- 改动以**最小化行为变更**为原则，除非该项明确标注为"行为变更"。

## 三、P0 详细设计（phase 1 必做）

### P0-1：补 CI lint

**问题**：
- `.github/workflows/ocserv.yml` L42-56 的 `sh -n` 和 `shellcheck` 步骤精确列出 6 个脚本，`install-docker.sh` 和 `scripts/occ` 都不在内。
- `docs/project-architecture.md` §五 L286-287 声称 bash 类脚本"在 CI 中通过 `bash -n` 检查"——**此声明与 CI 实际不符**。
- `.github/workflows/source-cache.yml` 的 `paths:` 触发器不含这两个文件，改动不触发 workflow。

**改动点**：

1. **`.github/workflows/ocserv.yml`**：
   - 在 `Check shell syntax` step 追加：
     ```yaml
     bash -n install-docker.sh
     bash -n scripts/occ
     ```
   - 在 `Lint shell scripts` step 追加：
     ```yaml
     shellcheck -s bash install-docker.sh
     shellcheck -s bash scripts/occ
     ```

2. **`.github/workflows/source-cache.yml`**：`paths:` 触发器追加 `install-docker.sh` 和 `scripts/occ`。

3. **`docs/project-architecture.md` §五 L286-287**：措辞从"归入这一类"改为明确列出 CI 检查命令，消除虚假声明。

4. **修 shellcheck 报错**：加 lint 后大概率报出一批 SC2086（未引用变量）、SC2155（`local x=$(cmd)` 掩码退出码）、SC2034（未用变量）。
   - **真实问题**：修掉（如 SC2155 改为 `local x; x=$(cmd)` 分离声明与赋值）。
   - **合理误报**：用 `# shellcheck disable=SCxxxx` 抑制（如 `$pkg_mgr` 在已知安全上下文）。
   - 预计修 10-20 处。

**验收**：CI 在 `install-docker.sh` 或 `scripts/occ` 变更时运行 lint 并通过。

### P0-2：修错误可见性（run_install helper）

**问题**（已逐行核验）：6 处 bare 静默安装命令，`set -e` 下安装失败 = 脚本静默退出，用户看不到 apt/dnf 原始报错：
- L361 `apt-get update -y >/dev/null 2>&1`
- L362 `apt-get install -y ca-certificates curl gnupg >/dev/null 2>&1`
- L384 `apt-get update -y >/dev/null 2>&1`
- L385 `apt-get install -y docker-ce ... >/dev/null 2>&1`（函数最后一条 = 返回码）
- L421 `$pkg_mgr install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1`
- L466 `dnf install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1`

**方案**：引入 `run_install` helper，统一所有安装命令的执行：

```bash
# 执行安装类命令。成功时静默（保持现有体验），失败时可见。
# --debug 模式下（P2-4）成功输出也可见。
run_install() {
  if [[ "${DEBUG:-false}" == true ]]; then
    "$@" || { log_error "命令失败 (退出码 $?): $*"; return 1; }
  else
    "$@" >/dev/null 2>&1 || { log_error "命令失败，请手动执行查看详情: $*"; return 1; }
  fi
}
```

**改造范围**：上述 6 处 bare 安装命令 + 其余受保护的安装命令（L417/418/420/456/465/473/476/486/488）统一走 `run_install`。受 `|| true` 保护的命令改为 `run_install ... || true`。

**行为保留**：成功时仍静默（DEBUG=false 默认）。失败时从静默退出变为 `log_error` + `return 1`，让上层决定退出策略。

**扩展性**：P2-4 的 `--debug` 模式直接复用此 helper。

## 四、P1 详细设计（phase 1 必做）

### P1-1：daemon.json 追加+去重（行为变更）

**问题**（已核验）：L561 `cfg['registry-mirrors'] = [url]` 是赋值覆盖，丢弃既有条目。与函数注释 L508-509"保留其他配置"矛盾（top-level key 保留了，但数组内条目被丢弃）。

**改为**：新源插入数组头部（最优优先），去重，限制总数 `MAX_MIRRORS=3`。

**新增常量**（顶部配置区，与现有 `readonly` 常量并列）：
```bash
readonly MAX_MIRRORS=3
```

**python3 路径**（L552-565）：
```python
existing = cfg.get('registry-mirrors', [])
cfg['registry-mirrors'] = [url] + [m for m in existing if m != url]
cfg['registry-mirrors'] = cfg['registry-mirrors'][:MAX_MIRRORS]
```

**jq 路径**（L568-570）：
```bash
jq --arg url "$new_url" --argjson max "$MAX_MIRRORS" \
  '.["registry-mirrors"] = ([$url] + (.["registry-mirrors"] // [] | map(select(. != $url))))[:$max]' \
  "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
```

**sed 降级路径**（L573-588）：sed 路径是 JSON 操作的最后兜底，复杂追加不现实。保持"覆盖为单源"行为，但更新注释说明降级路径的限制：
```bash
# sed 降级路径不支持追加去重，仅写入单源。如需保留多源，请安装 python3 或 jq。
```

**幂等性兼容**：`auto_configure_mirror` 的比对逻辑（L605 `grep -qxF "$DM_BEST_URL"`）天然兼容——新 URL 已在数组里就跳过，无需改。

**行为变更说明**（写入 changelog/PR 描述）：用户手动配的多源不再被丢弃，最优源插入头部，超出上限 3 的旧条目从尾部裁剪。

### P1-2：probe reduce 去重

**问题**（已核验）：`probe_pkg_mirrors` L231-242 ≡ `probe_docker_mirrors` L294-305 逐字相同。

**改为**：抽 `reduce_probe_results` helper：

```bash
# 从 tmpdir 的探测结果文件中选出延迟最小的 label。
# 参数: $1 = 结果目录
# 输出: "<label> <time_ms>"（成功）或空 + return 1（无有效结果）
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

两个 probe 函数改为调用它，差异只在后处理：
- `probe_pkg_mirrors`：`read -r label time <<< "$(reduce_probe_results "$tmpdir")"; PKG_MIRROR="$label"`
- `probe_docker_mirrors`：同样取 label，再查 URL 表设 `DM_BEST_HOST`/`DM_BEST_URL`

**HTTP 状态码白名单**（L282/325 重复 `^(200|401|403|404|301|302)$`）抽为顶部常量：
```bash
readonly HTTP_OK_CODES='^(200|401|403|404|301|302)$'
```

### P1-3：Oracle 分支独立

**问题**（已核验）：`install_docker` 的 `case` 里 `ol)` 分支（L451-467）内联，与 `install_docker_rpm` 重复：
- repo-guard（L403≡L458）
- backup（L406≡L461，逐字相同仅变量名不同）
- fallback install（L420-421≡L465-466，逐字相同仅 `$pkg_mgr` vs `dnf`）

**改为**：

1. **抽 `ensure_rpm_repo_file`**：
   ```bash
   # 确保 RPM repo 文件存在且配置 docker-ce。已存在则跳过，否则备份+创建。
   # 参数: $1 = repo 文件路径, 后续参数 = 创建命令（shift 后 $@ 调用）
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

2. **抽 `install_docker_pkgs_fallback`**：
   ```bash
   # 两步安装：先装全套插件(--nobest)，失败则降级为最小集。
   # 参数: $1 = 包管理器（yum/dnf）
   install_docker_pkgs_fallback() {
     local pkg_mgr="$1"
     run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io \
       docker-buildx-plugin docker-compose-plugin --nobest || \
     run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io
   }
   ```

3. **新增 `install_docker_ol()`**：用上面两个 helper，与 `install_docker_rpm` 对称。注意 Oracle 的 repo 创建用 `dnf config-manager --add-repo`（与 rpm 的 heredoc 不同），不能合并。

4. **`install_docker_rpm` 重构**：也改用 `ensure_rpm_repo_file` + `install_docker_pkgs_fallback`。

5. **`install_docker` 的 case**：`ol)` 分支改为调 `install_docker_ol`。

### P1-4：删死依赖

**问题**（已核验）：L10-13 软 source `scripts/common.sh`，但全文件 0 引用其任何符号。

**改为**：删 L9-13（含 `SCRIPT_DIR` 计算，仅为 source 用）。

**影响**：脚本完全独立，`curl | bash` 场景零外部依赖。`SCRIPT_DIR` 变量不再存在（已核验无其他用途）。

## 五、P2 详细设计（phase 2 选做）

### P2-1：exit→return 统一

**问题**：叶子函数 `exit 1`（L106/107/108 `check_prerequisites`、L97 `parse_args`、L478 `install_docker` 的 `*)`）破坏可单测性。

**改为**：
- `check_prerequisites`：3 处 `exit 1` → `return 1`，`main` 里改 `check_prerequisites || exit 1`
- `parse_args`：`-h` 保持 `exit 0`（CLI 合理行为），`*)` 保持 `exit 1`（参数错误立即退出合理）
- `install_docker` 的 `*)`：`exit 1` → `return 1`（`main` 里 `install_docker` bare 调用，`set -e` 会传播）

### P2-2：补 .shellcheckrc

新增仓库根 `.shellcheckrc`：
```
disable=SC2312
```
（SC2312 是 shellcheck 自己的"考虑单独调用此命令"推荐，对 `run_install "$@"` 模式有误报。）

### P2-3：parse_args 组合校验

**当前**：零组合校验。

**分析**：本项目当前 flag 组合（`--no-mirror`/`--force`/`--skip-cloud`/`--yes`）无真正互斥关系。

**改为**：加 `validate_args()` 空框架 + 注释：
```bash
# 参数组合校验。当前无互斥约束；新增 flag 时在此校验。
validate_args() {
  :
}
```
`parse_args` 末尾、`main` 开头各调一次。

### P2-4：--debug 模式

**新增**：`--debug` flag，置 `DEBUG=true`。`run_install` helper（P0-2）根据 `DEBUG` 切换：
- `DEBUG=false`（默认）：`"$@" >/dev/null 2>&1`
- `DEBUG=true`：`"$@"`（输出可见）

`parse_args` 追加 `--debug) DEBUG=true; shift ;;`。`--help` 文本追加说明。

### P2-5：Debian codename 兜底改进

**当前**（L372-379）：硬编码 11/12/13，未知默认 bookworm。

**改为**：优先信任 `VERSION_CODENAME`（现代 Debian 都有），仅在空或 `stable` 时查映射表：
```bash
codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
if [[ -z "$codename" || "$codename" == "stable" ]]; then
  # 兜底映射表（老版本 Debian 无 VERSION_CODENAME）
  local debian_ver="${VERSION_ID%%.*}"
  case "$debian_ver" in
    11) codename="bullseye" ;;
    12) codename="bookworm" ;;
    13) codename="trixie" ;;
    *)  codename="bookworm" ;;
  esac
fi
```

## 六、验收标准

### P0
- [ ] CI 在 `install-docker.sh` 或 `scripts/occ` 变更时运行 `bash -n` + `shellcheck` 并通过
- [ ] `docs/project-architecture.md` §五 的 CI 声明与实际一致
- [ ] `install-docker.sh` 安装失败时，stderr 输出失败命令与提示
- [ ] `shellcheck -s bash install-docker.sh` 零 error（disable 注释除外）

### P1
- [ ] `daemon.json` 已有多源时，新源插入头部、去重、不超 3 个
- [ ] `registry-mirrors` 已包含最优源时跳过写入（幂等）
- [ ] `reduce_probe_results` 被 `probe_pkg_mirrors` 和 `probe_docker_mirrors` 共用，无重复代码
- [ ] `install_docker_ol` 独立函数，与 `install_docker_rpm` 共享 helper
- [ ] `install-docker.sh` 无 `source common.sh`，无 `SCRIPT_DIR` 变量
- [ ] `curl ... | bash` 形式（脱离仓库）仍可运行（standalone）

### P2
- [ ] `check_prerequisites` 失败时 `main` 正确处理（非脚本内 exit）
- [ ] `.shellcheckrc` 存在且 CI 使用
- [ ] `install-docker.sh --debug` 时安装命令输出可见
- [ ] Debian 无 `VERSION_CODENAME` 时走兜底映射表

## 七、测试策略

**手动测试**（bash 脚本无单元测试框架，靠场景验证）：

1. **语法/lint**：本地 `bash -n install-docker.sh` + `shellcheck -s bash install-docker.sh` 通过
2. **standalone**：`curl -sL <raw-url> | bash -s -- --help` 在无仓库的环境可运行
3. **daemon.json 追加**：预置含 2 个源的 daemon.json，跑脚本，验证新源插入头部、总数≤3、旧源保留
4. **daemon.json 幂等**：再次跑脚本，验证不重复写入
5. **安装失败可见性**：mock 一个包名（如 `docker-ce-nonexistent`），验证 `log_error` 输出命令
6. **probe 去重**：验证 `reduce_probe_results` 在两个 probe 函数中行为一致
7. **CI 绿灯**：PR 触发 workflow，lint 步骤通过

**回归保护**：现有 12 个发行版的安装路径不可破坏。重点回归 Ubuntu（apt）、CentOS/Rocky（rpm）、Oracle（ol）三条主路径。

## 八、风险与缓解

| 风险 | 缓解 |
|------|------|
| shellcheck 报错过多，PR 过大 | 分批：P0-1 单独一个 commit，修 shellcheck 报错单独一个 commit |
| `run_install` 改造面大，遗漏某处 | 改造后全文 grep `>/dev/null 2>&1` 确认安装类命令全覆盖 |
| daemon.json 追加改坏了已有配置 | 预置测试用例覆盖：空文件、单源、多源、含其他 key |
| 删 source 后 standalone 失败 | 用 `curl \| bash` 形式实测 `--help` |
| Oracle 分支重构引入回归 | `install_docker_ol` 的 repo 创建逻辑（`dnf config-manager --add-repo`）与 rpm 的 heredoc 不同，不能合并，只共享 helper |

## 九、交付物

修改的文件：
- `install-docker.sh`（主体）
- `scripts/occ`（仅 shellcheck 修复）
- `.github/workflows/ocserv.yml`
- `.github/workflows/source-cache.yml`
- `docs/project-architecture.md`
- `.shellcheckrc`（P2-2 新增）

不动：
- `scripts/common.sh`、`scripts/prepare-ocserv-config.sh`、`scripts/render-ocserv-conf.sh`、`docker/ocserv/*`（P1-4 删 source 不影响它们）

## 十、执行顺序建议

1. P1-4 删死依赖（最小、独立、先做）
2. P0-2 `run_install` helper（P1-3 依赖它）
3. P1-2 probe 去重 + P1-3 Oracle 独立（互不依赖，可一并）
4. P1-1 daemon.json 追加
5. P0-1 补 CI lint（最后做，把前面的改动一起 lint）
6. P2 项（phase 2，可后续 PR）

> 这个顺序让每步改动最小化、可独立验证。

## 十一、证据索引

所有断言均已逐行核验，证据位置：

| 断言 | 证据位置 |
|------|----------|
| CI 漏掉 install-docker.sh | `ocserv.yml` L42-56 |
| 文档虚假声称 CI 覆盖 | `project-architecture.md` L286-287 |
| common.sh 死依赖 | L10-13 source，全文件 0 引用 |
| reduce 循环逐字重复 | L231-242 ≡ L294-305 |
| Oracle 分支重复 rpm 惯用法 | L406≡L461, L420-421≡L465-466 |
| daemon.json 覆盖非追加 | L561 `= [url]`，jq L569，sed L576/582/587 |
| 6 处 bare 静默安装 | L361/362/384/385/421/466 |
| L738-740 失败即杀脚本 | `install_docker` bare 调用 + `set -e` |
| parse_args 零组合校验 | L79-100 无 post-parse 步骤 |
| DMI 兜底在云上几乎不可达 | L700-703 metadata 成功即 return |
