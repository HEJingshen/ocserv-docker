#!/usr/bin/env bash
# ============================================================
# 生产级 Docker 一键安装与优化脚本 (v3.1)
# 特性: 严格模式 / 智能配置比对 / 并发探测 / 多云适配 / 幂等执行 / CI 友好
# 兼容: Ubuntu/Debian/CentOS/Rocky/Alma/Fedora/openEuler/HCE/Alinux/TencentOS/OpenCloudOS/OracleLinux
# ============================================================
set -euo pipefail

# --- 颜色与日志 (统一输出至 stderr，避免污染 stdout 管道) ---
readonly GREEN='\033[0;32m' YELLOW='\033[1;33m' RED='\033[0;31m' BLUE='\033[0;34m' NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*" >&2; }

# --- 全局配置 ---
readonly SUPPORTED_DISTROS="ubuntu|debian|centos|fedora|rocky|almalinux|tencentos|opencloudos|alinux|hce|openeuler|ol"
declare -A MIRRORS=(
  [aliyun]="mirrors.aliyun.com"
  [tencent]="mirrors.cloud.tencent.com"
  [huawei]="repo.huaweicloud.com"
  [tuna]="mirrors.tuna.tsinghua.edu.cn"
)
readonly MIRROR_PROBE_COUNT=3

# Docker 镜像加速源列表（含代理型 & 缓存型，按推荐优先级排序）
readonly DOCKER_MIRROR_URLS=(
  "https://docker.m.daocloud.io"
  "https://docker.1ms.run"
  "https://docker.xuanyuan.me"
  "https://mirror.ccs.tencentyun.com"
)

# 保底加速源（当全部探测失败时强制使用）
readonly DOCKER_FALLBACK_MIRRORS=(
  "https://docker.m.daocloud.io"
  "https://docker.1ms.run"
)

readonly DOCKER_MIRROR_PROBE_COUNT=3
readonly HTTP_OK_CODES='^(200|401|403|404|301|302)$'

# --- 状态变量 ---
DH_STATUS="UNKNOWN" DH_CFG_STATUS="NOT_CONFIGURED"
DM_BEST_HOST="" DM_BEST_URL="" PKG_MIRROR=""
OS_TYPE="" OS_VERSION=""
TMPDIR_BASE="" SKIP_CLOUD=false FORCE_INSTALL=false NO_MIRROR=false YES_MODE=false DEBUG=false

# --- 安装命令执行封装 (成功静默，失败可见；--debug 时全可见) ---
run_install() {
  if [[ "${DEBUG:-false}" == true ]]; then
    "$@" || { log_error "命令失败 (退出码 $?): $*"; return 1; }
  else
    "$@" >/dev/null 2>&1 || { log_error "命令失败，请手动执行查看详情: $*"; return 1; }
  fi
}

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

# --- 并发任务限制 (bg_throttle / bg_wait_all) ---
# 在 ( ... ) & 后调用 bg_throttle <max> 来限制并发数;
# 全部任务结束后调用 bg_wait_all 等待并重置计数器。
_bg_count=0
bg_throttle() {
  local max=$1
  _bg_count=$((_bg_count + 1))
  if (( _bg_count >= max )); then
    if [[ "${BASH_VERSINFO[0]:-3}" -ge 4 && "${BASH_VERSINFO[1]:-0}" -ge 3 ]]; then
      wait -n 2>/dev/null || true
    else
      wait
    fi
    _bg_count=$((_bg_count - 1))
  fi
}
bg_wait_all() { wait; _bg_count=0; }

# --- 安全清理 ---
cleanup() {
  [[ -n "${TMPDIR_BASE:-}" && -d "$TMPDIR_BASE" ]] && rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT INT TERM

# --- CLI 解析 ---
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-mirror)      NO_MIRROR=true; shift ;;
      --force)          FORCE_INSTALL=true; shift ;;
      --skip-cloud)     SKIP_CLOUD=true; shift ;;
      -y|--yes)         YES_MODE=true; shift ;;
      -h|--help)
        cat >&2 <<EOF
用法: $0 [选项]
选项:
  --no-mirror    跳过镜像加速配置
  --force        强制重新安装 Docker
  --skip-cloud   跳过云厂商检测
  -y, --yes      非交互模式（自动确认所有提示，适合 CI/CD）
  -h, --help     显示帮助
EOF
        exit 0 ;;
      *) log_error "未知参数: $1"; exit 1 ;;
    esac
  done
}

# ============================================================
# 模块 0：前置检查
# ============================================================
check_prerequisites() {
  [[ $EUID -ne 0 ]] && { log_error "请使用 root 用户或 sudo 执行此脚本"; exit 1; }
  command -v curl &>/dev/null || { log_error "未找到 curl，请先安装"; exit 1; }
  TMPDIR_BASE=$(mktemp -d) || { log_error "无法创建临时目录"; exit 1; }
}

# ============================================================
# 模块 1：Docker Hub 网络与配置检测
# ============================================================
check_network() {
  local metrics
  metrics=$(LC_ALL=C curl -s -o /dev/null -w "%{time_namelookup} %{time_connect} %{time_starttransfer} %{http_code}" \
    --connect-timeout 5 --max-time 8 \
    https://registry-1.docker.io/v2/ 2>/dev/null) || metrics="0 0 0 000"

  local dns_t conn_t ttfb_t http_code
  read -r dns_t conn_t ttfb_t http_code <<< "$metrics"
  # 安全兜底：避免空值导致 awk 语法错误
  dns_t=${dns_t:-0}; conn_t=${conn_t:-0}; ttfb_t=${ttfb_t:-0}

  local dns_ms conn_ms ttfb_ms
  dns_ms=$(awk "BEGIN {printf \"%.0f\", ${dns_t} * 1000}")
  conn_ms=$(awk "BEGIN {printf \"%.0f\", ${conn_t} * 1000}")
  ttfb_ms=$(awk "BEGIN {printf \"%.0f\", ${ttfb_t} * 1000}")

  local status="UNKNOWN"
  if [[ "$http_code" == "000" ]]; then status="BLOCKED"
  elif (( ttfb_ms > 4000 )); then status="SLOW"
  elif (( ttfb_ms > 1500 )); then status="FAIR"
  else status="GOOD"; fi

  echo "$status $dns_ms $conn_ms $ttfb_ms $http_code"
}

check_docker_config() {
  local conf="/etc/docker/daemon.json"
  if [[ -f "$conf" ]] && grep -q '"registry-mirrors"' "$conf" 2>/dev/null; then
    # 确认 registry-mirrors 中有有效的 URL
    local urls
    urls=$(extract_existing_mirrors "$conf" 2>/dev/null) || true
    if [[ -n "$urls" ]]; then
      echo "CONFIGURED"
      return 0
    fi
  fi
  echo "NOT_CONFIGURED"
}

check_docker_hub() {
  log_step "正在测试 Docker Hub 官方源网络质量..."
  local net_result status dns_ms conn_ms ttfb_ms http_code cfg_status
  net_result=$(check_network)
  read -r status dns_ms conn_ms ttfb_ms http_code <<< "$net_result"
  [[ "$http_code" == "000" ]] && http_code="TIMEOUT"
  cfg_status=$(check_docker_config)

  DH_STATUS="$status"; DH_CFG_STATUS="$cfg_status"

  log_info "📊 网络延迟: DNS=${dns_ms}ms | TCP=${conn_ms}ms | TTFB=${ttfb_ms}ms | HTTP=${http_code}"
  log_info "⚙️  Docker 配置状态: ${cfg_status}"

  case "$status" in
    GOOD)     log_info "✅ 网络质量优秀，可直接拉取官方镜像。" ;;
    FAIR)     log_warn "⚠️  网络质量一般，建议配置镜像加速。" ;;
    SLOW|BLOCKED) log_error "❌ 官方源不可达，必须配置加速或代理。" ;;
    *)        log_error "❓ 网络检测异常，请检查防火墙/DNS。" ;;
  esac
}

# ============================================================
# 模块 2：OS 检测
# ============================================================
init_os_vars() {
  [[ -f /etc/os-release ]] || { log_error "/etc/os-release 不存在"; return 1; }
  # shellcheck source=/etc/os-release
  . /etc/os-release
  local distro="${ID,,}"
  [[ "$distro" =~ ^($SUPPORTED_DISTROS)$ ]] || { log_error "不支持的发行版: $distro"; return 1; }

  OS_TYPE="$distro"
  if [[ "$distro" =~ ^(opencloudos|centos|tencentos|openeuler|alinux|rocky|almalinux|fedora|ol)$ && -n "${VERSION_ID:-}" ]]; then
    OS_VERSION="${VERSION_ID%%.*}"
  fi
  log_info "🖥️  检测到系统: $OS_TYPE ${OS_VERSION:-}"
}

# ============================================================
# 模块 3：并发延迟探测 — 包镜像源
# ============================================================
probe_pkg_mirrors() {
  local -a targets=()
  for name in "${!MIRRORS[@]}"; do targets+=("${MIRRORS[$name]}|$name"); done

  local tmpdir="$TMPDIR_BASE/probe_pkg"
  mkdir -p "$tmpdir"

  for entry in "${targets[@]}"; do
    IFS='|' read -r target label <<< "$entry"
    for ((i=1; i<=MIRROR_PROBE_COUNT; i++)); do
      (
        local time_ms
        if command -v ping &>/dev/null; then
          local result
          result=$(ping -c 1 -W 3 "$target" 2>/dev/null) || exit 0
          time_ms=$(echo "$result" | grep -o 'time=[0-9.]*' | head -1 | cut -d= -f2) || exit 0
        else
          # 容器无 ping，用 curl HTTP 探测兜底
          local http_code total_time curl_out
          curl_out=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
            --connect-timeout 3 --max-time 5 "https://${target}/" 2>/dev/null) || exit 0
          http_code=$(echo "$curl_out" | awk '{print $1}')
          total_time=$(echo "$curl_out" | awk '{print $2}')
          [[ -z "$http_code" || -z "$total_time" ]] && exit 0
          [[ "$http_code" =~ ^(200|301|302|403)$ ]] || exit 0
          time_ms=$(awk "BEGIN{printf \"%.2f\", ${total_time} * 1000}")
        fi

        # 只有 time_ms 非空且为数字时才写入
        [[ -n "$time_ms" && "$time_ms" =~ ^[0-9]+\.?[0-9]*$ ]] && \
          echo "$time_ms" > "$tmpdir/${label}_${i}"
      ) &
      bg_throttle 8
    done
  done
  bg_wait_all

  local result best_label best_time
  result=$(reduce_probe_results "$tmpdir")
  rm -rf "$tmpdir"

  if [[ -n "$result" ]]; then
    read -r best_label best_time <<< "$result"
    PKG_MIRROR="$best_label"
    log_info "✅ 最快包镜像源: $best_label (${MIRRORS[$best_label]}) | ${best_time}ms"
    return 0
  fi
  return 1
}

# ============================================================
# 模块 4：并发延迟探测 — Docker 镜像源
# ============================================================
probe_docker_mirrors() {
  local -a targets=()
  for url in "${DOCKER_MIRROR_URLS[@]}"; do
    local h="${url#https://}"; h="${h%%/*}"
    targets+=("${url}|${h}")
  done

  local tmpdir="$TMPDIR_BASE/probe_docker"
  mkdir -p "$tmpdir"

  for entry in "${targets[@]}"; do
    IFS='|' read -r target label <<< "$entry"
    for ((i=1; i<=DOCKER_MIRROR_PROBE_COUNT; i++)); do
      (
        local http_code total_time curl_out time_ms
        curl_out=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
          --connect-timeout 3 --max-time 6 "${target}/v2/" 2>/dev/null) || exit 0

        http_code=$(echo "$curl_out" | awk '{print $1}')
        total_time=$(echo "$curl_out" | awk '{print $2}')

        # 放宽 HTTP 状态码检查 (200/401/403/404 均可视为可达)
        # 很多国内代理镜像 /v2/ 返回 403/404 但 pull 实际可用
        [[ -z "$http_code" || -z "$total_time" ]] && exit 0
        # shellcheck disable=SC2076
        [[ "$http_code" =~ $HTTP_OK_CODES ]] || exit 0

        time_ms=$(awk "BEGIN{printf \"%.2f\", ${total_time} * 1000}")

        [[ -n "$time_ms" && "$time_ms" =~ ^[0-9]+\.?[0-9]*$ ]] && \
          echo "$time_ms" > "$tmpdir/${label}_${i}"
      ) &
      bg_throttle 8
    done
  done
  bg_wait_all

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

  # 探测全部失败时，使用保底加速源
  log_warn "⚠️  所有Docker加速源探测均失败，尝试使用保底源..."
  for fb_url in "${DOCKER_FALLBACK_MIRRORS[@]}"; do
    local fb_host fb_code
    fb_host="${fb_url#https://}"
    fb_code=$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout 3 --max-time 5 "${fb_url}/v2/" 2>/dev/null) || fb_code="000"
        # shellcheck disable=SC2076
    if [[ "$fb_code" =~ $HTTP_OK_CODES ]]; then
      DM_BEST_HOST="$fb_host"
      DM_BEST_URL="$fb_url"
      log_info "✅ 使用保底Docker加速源: $fb_host (HTTP $fb_code)"
      return 0
    fi
  done
  log_error "❌ 所有Docker加速源（含保底）均不可达"
  return 1
}

# ============================================================
# 模块 5：Docker 安装 (安全加固版)
# ============================================================
check_docker_installed() {
  if [[ "$FORCE_INSTALL" != true ]] && command -v docker &>/dev/null && docker info &>/dev/null; then
    log_info "✅ Docker 已安装: $(docker --version)"
    return 0
  fi
  return 1
}

safe_gpg_download() {
  local url="$1" dest="$2"
  curl -fsSL --connect-timeout 5 --max-time 10 "$url" -o "$dest" 2>/dev/null || return 1
  # 🔧 修复: `file` 命令在最小化系统可能未安装，改用文件大小+内容前缀校验
  local size
  size=$(wc -c < "$dest" 2>/dev/null) || return 1
  (( size > 100 )) || return 1
  # GPG key 文件通常以 "-----BEGIN PGP" 开头
  head -c 27 "$dest" 2>/dev/null | grep -q "-----BEGIN" || return 1
  return 0
}

# --- APT 系 (Ubuntu / Debian) ---
install_docker_apt() {
  run_install apt-get update -y
  run_install apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  safe_gpg_download "${repo_gpg}/${OS_TYPE}/gpg" /etc/apt/keyrings/docker.asc || { log_error "GPG 下载失败"; return 1; }
  chmod a+r /etc/apt/keyrings/docker.asc

  local arch codename
  arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
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
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] ${repo_url}/${OS_TYPE} ${codename} stable" | \
    tee /etc/apt/sources.list.d/docker.list >/dev/null

  run_install apt-get update -y
  run_install apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# --- RPM 系 (CentOS/Rocky/Alma/Fedora/openEuler/HCE/OpenCloudOS/Alinux) ---
install_docker_rpm() {
  local pkg_mgr="yum"; command -v dnf &>/dev/null && pkg_mgr="dnf"
  local repo_file="/etc/yum.repos.d/docker-ce.repo"

  local base_ver="${OS_VERSION:-8}"
  [[ "$OS_TYPE" == "openeuler" && "$OS_VERSION" == "22" ]] && base_ver="8"
  [[ "$OS_TYPE" == "openeuler" && "$OS_VERSION" == "24" ]] && base_ver="9"
  [[ "$OS_TYPE" == "alinux" ]] && {
    case "${OS_VERSION:-3}" in 2) base_ver="7";; 3) base_ver="8";; 4) base_ver="9";; esac
  }

  local target_repo_url="${repo_url}/centos"
  [[ "$OS_TYPE" == "fedora" ]] && target_repo_url="${repo_url}/fedora"

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

  run_install "$pkg_mgr" install -y yum-utils || true
  [[ "$base_ver" =~ ^(9|10)$ ]] && run_install "$pkg_mgr" install -y libnftables || true

  run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest || \
  run_install "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io
}

install_docker() {
  log_step "开始安装 Docker (OS: $OS_TYPE)..."
  local use_mirror=false
  [[ "$DH_STATUS" != "GOOD" && -n "$PKG_MIRROR" ]] && use_mirror=true

  local mirror_base="" mirror_proto="https"
  if [[ "$use_mirror" == true ]]; then
    mirror_base="${MIRRORS[$PKG_MIRROR]}"
    [[ "$mirror_base" == *"aliyuncs.com"* || "$mirror_base" == *"aliyun.com"* ]] && mirror_proto="http"
  fi

  local repo_url repo_gpg
  if [[ "$use_mirror" == true ]]; then
    repo_url="${mirror_proto}://${mirror_base}/docker-ce/linux"
    repo_gpg="${mirror_proto}://${mirror_base}/docker-ce/linux"
  else
    repo_url="https://download.docker.com/linux"
    repo_gpg="https://download.docker.com/linux"
  fi

  case "$OS_TYPE" in
    ubuntu|debian)
      install_docker_apt
      ;;
    centos|rocky|almalinux|fedora|openeuler|hce|opencloudos|alinux)
      install_docker_rpm
      ;;
    ol)
      if ! command -v dnf &>/dev/null; then
        log_error "❌ Oracle Linux 需要 dnf，但未找到"
        return 1
      fi
      run_install dnf install -y dnf-plugins-core || true
      local docker_repo="/etc/yum.repos.d/docker-ce.repo"
      if [[ -f "$docker_repo" ]] && grep -q "docker-ce" "$docker_repo" 2>/dev/null; then
        log_info "📦 Docker repo 已存在，跳过创建"
      else
        [[ -f "$docker_repo" ]] && cp -f "$docker_repo" "${docker_repo}.bak.$(date +%s)" 2>/dev/null || true
        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1 || \
          { log_error "❌ 添加 Docker 仓库失败"; return 1; }
      fi
      run_install dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest || \
      run_install dnf install -y docker-ce docker-ce-cli containerd.io
      ;;
    tencentos)
      if command -v docker &>/dev/null; then
        log_info "📦 TencentOS 预装 Docker: $(docker --version)"
      else
        local pkg_mgr="dnf"; [[ "${OS_VERSION:-4}" == "4" ]] && pkg_mgr="yum"
        run_install "$pkg_mgr" install -y docker-ce --nobest || run_install "$pkg_mgr" install -y docker
      fi
      # 确保预装的 Docker 已启用并自启
      command -v systemctl &>/dev/null && run_install systemctl enable --now docker || true
      ;;
    *) log_error "❌ 不支持的 OS: $OS_TYPE"; return 1 ;;
  esac

  command -v docker &>/dev/null || { log_error "❌ Docker 安装失败"; return 1; }

  # 启动 Docker 守护进程
  log_step "验证 Docker 守护进程状态..."
  if command -v systemctl &>/dev/null; then
    run_install systemctl enable --now docker || true
  elif command -v service &>/dev/null; then
    run_install service docker start || true
  fi

  if docker info &>/dev/null; then
    log_info "✅ Docker 安装成功: $(docker --version)"
  else
    log_warn "⚠️  Docker 已安装但守护进程未响应，尝试手动启动..."
    dockerd --version &>/dev/null && { nohup dockerd > /var/log/dockerd.log 2>&1 & }
    sleep 2
    if docker info &>/dev/null; then
      log_info "✅ Docker 安装并启动成功: $(docker --version)"
    else
      log_error "❌ Docker 守护进程启动失败，请查看 /var/log/dockerd.log"
      return 1
    fi
  fi
}

# ============================================================
# 模块 6：安全配置 daemon.json
# 策略：先读取已有配置，比较加速源地址；
#       若一致 → 跳过；若不同 → 仅替换 registry-mirrors，保留其他配置
# ============================================================

# 🔧 优化: 提取 daemon.json 中所有 registry-mirrors URLs
# 返回多行输出，便于后续比对任一匹配
extract_existing_mirrors() {
  local conf="$1"
  [[ -f "$conf" ]] || return 1

  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    for m in cfg.get('registry-mirrors', []):
        print(m)
    sys.exit(0)
except: pass
sys.exit(1)
" "$conf" 2>/dev/null && return 0
  fi

  if command -v jq &>/dev/null; then
    local urls
    urls=$(jq -r '.["registry-mirrors"][]? // empty' "$conf" 2>/dev/null)
    [[ -n "$urls" ]] && { echo "$urls"; return 0; }
  fi

  # grep 降级提取
  local raw
  raw=$(grep -o '"registry-mirrors"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$conf" 2>/dev/null | head -1) || true
  if [[ -n "$raw" ]]; then
    echo "$raw" | grep -o 'https://[^"]*\|http://[^"]*'
    return 0
  fi

  return 1
}

safe_update_daemon_json() {
  local conf="$1" new_url="$2"

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

  if command -v jq &>/dev/null; then
    jq --arg url "$new_url" '.["registry-mirrors"] = [$url]' "$conf" > "${conf}.tmp" 2>/dev/null && \
    mv "${conf}.tmp" "$conf" && return 0
  fi

  # sed 最终降级：仅改 registry-mirrors，不碰其他字段
  if [[ -f "$conf" ]]; then
    if grep -q '"registry-mirrors"' "$conf"; then
      sed -i "s|\"registry-mirrors\"[[:space:]]*:[[:space:]]*\[[^]]*\]|\"registry-mirrors\": [\"${new_url}\"]|" "$conf"
    elif grep -q '{' "$conf"; then
      # 文件有内容但无 registry-mirrors，插入到第一个 { 之后
      sed -i "0,/{/s/{/{\n  \"registry-mirrors\": [\"${new_url}\"],/" "$conf"
    else
      # 文件非 JSON 格式，安全重建
      printf '{\n  "registry-mirrors": ["%s"]\n}\n' "$new_url" > "$conf"
    fi
    return 0
  fi

  printf '{\n  "registry-mirrors": ["%s"]\n}\n' "$new_url" > "$conf"
  return 0
}

auto_configure_mirror() {
  [[ "$NO_MIRROR" == true ]] && { log_info "⏭️  跳过镜像加速配置 (--no-mirror)"; return 0; }
  case "$DH_STATUS" in GOOD) return 0 ;; esac
  [[ -z "$DM_BEST_URL" ]] && { log_warn "⚠️  无可用加速源，跳过配置"; return 0; }

  local conf="/etc/docker/daemon.json"
  log_step "正在检查 Docker 镜像加速配置..."

  # 智能比对：检查新 URL 是否已在已有镜像列表中
  local existing_mirrors=""
  existing_mirrors=$(extract_existing_mirrors "$conf" 2>/dev/null) || true

  if [[ -n "$existing_mirrors" ]]; then
    # 🔧 修复: 遍历所有已有镜像，只要有一个匹配就跳过
    if echo "$existing_mirrors" | grep -qxF "$DM_BEST_URL"; then
      log_info "✅ daemon.json 已包含最优加速源: $DM_BEST_URL，无需修改"
      return 0
    fi
    log_info "📊 当前加速源: $(echo "$existing_mirrors" | head -1)"
    log_info "📊 最优加速源: $DM_BEST_URL（延迟更低）"
    log_info "🔄 将替换为最优加速源，其他配置保持不变"
  elif [[ -f "$conf" ]]; then
    log_info "📊 daemon.json 存在但未配置 registry-mirrors，将新增配置"
  else
    log_info "📊 daemon.json 不存在，将创建新文件"
  fi

  # 需要修改 → 先备份
  if [[ -f "$conf" ]]; then
    local bak="${conf}.bak.$(date +%s)"
    cp -f "$conf" "$bak" && log_info "📦 已备份原配置: $bak"
  fi

  if ! safe_update_daemon_json "$conf" "$DM_BEST_URL"; then
    log_error "❌ 配置写入失败，请手动检查 $conf"
    return 1
  fi
  log_info "✅ 配置已安全写入: $conf"

  # 使配置生效
  if systemctl is-active --quiet docker 2>/dev/null; then
    local running_containers
    running_containers=$(docker ps -q 2>/dev/null | wc -l)
    if (( running_containers > 0 )); then
      log_warn "⚠️  检测到 $running_containers 个运行中的容器，重启 Docker 将中断它们"
      if [[ "${YES_MODE:-false}" == "true" ]]; then
        log_info "🤖 非交互模式，自动跳过重启，配置将在下次 Docker 启动时生效"
        return 0
      fi
      read -r -p "是否立即重启 Docker 使配置生效? [y/N]: " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "⏸️  跳过重启，配置将在下次 Docker 启动时生效"; return 0; }
    fi
    systemctl daemon-reload
    systemctl restart docker
    log_info "✅ Docker 已重启，加速生效"
  else
    systemctl daemon-reload 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    log_info "✅ 配置已写入，Docker 启动后自动生效"
  fi
}

# ============================================================
# 模块 7：云厂商检测 (Metadata → DMI)
# ============================================================
detect_cloud() {
  [[ "$SKIP_CLOUD" == true ]] && return 0
  log_step "正在检测云厂商环境..."

  local result_file="$TMPDIR_BASE/cloud_detect"
  : > "$result_file"

  local aws_token=""
  aws_token=$(curl -s --connect-timeout 1 --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null) || true

  local -a endpoints=(
    "http://169.254.169.254/latest/meta-data/ami-id|AWS"
    "http://100.100.100.200/latest/meta-data/instance-id|Aliyun"
    "http://metadata.tencentyun.com/latest/meta-data/instance-id|Tencent"
    "http://169.254.169.254/metadata/instance?api-version=2021-02-01|Azure"
    "http://169.254.169.254/computeMetadata/v1/instance/id|GCP"
    "http://169.254.169.254/openstack/latest/meta_data.json|Huawei"
    "http://169.254.169.254/opc/v1/instance/|OracleCloud"
  )

  for ep in "${endpoints[@]}"; do
    IFS='|' read -r url cloud <<< "$ep"
    (
      local args=(-s --connect-timeout 1 --max-time 2)
      [[ "$cloud" == "AWS" && -n "$aws_token" ]] && args+=(-H "X-aws-ec2-metadata-token: $aws_token")
      [[ "$cloud" == "Azure" ]] && args+=(-H "Metadata: true")
      [[ "$cloud" == "GCP" ]] && args+=(-H "Metadata-Flavor: Google")

      local resp
      resp=$(curl "${args[@]}" "$url" 2>/dev/null) || exit 0
      case "$cloud" in
        AWS)     [[ "$resp" == ami-* ]] && echo "$cloud" > "$result_file" ;;
        Aliyun|Tencent) [[ "$resp" =~ ^[iins] ]] && echo "$cloud" > "$result_file" ;;
        Azure)   [[ "$resp" == *azure* ]] && echo "$cloud" > "$result_file" ;;
        GCP)     [[ "$resp" =~ ^[0-9]+$ ]] && echo "$cloud" > "$result_file" ;;
        Huawei)  [[ "$resp" == *huawei* ]] && echo "$cloud" > "$result_file" ;;
        OracleCloud) [[ "$resp" == *oracle* || "$resp" == *availabilityDomain* || "$resp" == *compartmentId* ]] && echo "$cloud" > "$result_file" ;;
      esac
    ) &
    bg_throttle 7
  done
  bg_wait_all

  if [[ -s "$result_file" ]]; then
    log_info "✅ 云厂商识别: $(cat "$result_file")"
    return 0
  fi

  local vendor product
  vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) || true
  product=$(cat /sys/class/dmi/id/product_name 2>/dev/null) || true
  local dmi="${vendor,,} ${product,,}"

  case "$dmi" in
    *amazon*|*ec2*)        log_info "✅ DMI 识别: AWS"; return 0 ;;
    *alibaba*|*aliyun*)    log_info "✅ DMI 识别: 阿里云"; return 0 ;;
    *tencent*|*qcloud*)    log_info "✅ DMI 识别: 腾讯云"; return 0 ;;
    *openstack*|*huawei*)  log_info "✅ DMI 识别: 华为云"; return 0 ;;
    *microsoft*|*azure*)   log_info "✅ DMI 识别: Azure"; return 0 ;;
    *google*|*gce*)        log_info "✅ DMI 识别: GCP"; return 0 ;;
    *oracle*)              log_info "✅ DMI 识别: Oracle Cloud"; return 0 ;;
  esac
  log_warn "⚠️  未识别到主流云厂商 (可能为物理机/本地VM/容器)"
}

# ============================================================
# Main — 执行入口
# ============================================================
main() {
  parse_args "$@"
  check_prerequisites
  init_os_vars

  check_docker_hub
  echo ""

  log_step "探测最优镜像源..."
  probe_pkg_mirrors || log_warn "⚠️  包镜像源探测失败，将使用默认源"
  probe_docker_mirrors || log_warn "⚠️  Docker加速源探测失败（已尝试保底源）"
  echo ""

  if ! check_docker_installed; then
    install_docker
  fi

  auto_configure_mirror
  echo ""
  detect_cloud

  log_info "🎉 脚本执行完成"
}

main "$@"
