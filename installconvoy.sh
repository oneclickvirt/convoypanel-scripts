#!/usr/bin/env bash
# by spiritlhl
# from https://github.com/oneclickvirt/convoypanel-scripts
# Convoy Panel installer with strict error handling, logging, rollback, and bilingual output.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

CONVOY_INSTALL_DIR="${CONVOY_INSTALL_DIR:-/var/www/convoy}"
CONVOY_VERSION="${CONVOY_VERSION:-latest}"
BROKER_VERSION="${BROKER_VERSION:-latest}"
MIN_PVE_VERSION="${MIN_PVE_VERSION:-7.2}"
MIN_MEMORY_MB="${MIN_MEMORY_MB:-4000}"
MIN_DISK_MB="${MIN_DISK_MB:-10240}"
LOG_DIR="${CONVOY_LOG_DIR:-/var/log/convoypanel-scripts}"
LOG_FILE="${CONVOY_LOG_FILE:-$LOG_DIR/install-$TIMESTAMP.log}"
STATE_DIR="${CONVOY_STATE_DIR:-/var/tmp/convoypanel-install-$TIMESTAMP}"
PVE_USERID="${PVE_USERID:-root@pam}"
PVE_TOKEN_ID="${PVE_TOKEN_ID:-convoy}"
ROLLBACK_ON_ERROR="${ROLLBACK_ON_ERROR:-1}"
FORCE_INSTALL="${CONVOY_FORCE:-0}"
SKIP_NETWORK_CHECK="${CONVOY_SKIP_NETWORK_CHECK:-0}"
SKIP_SWAP="${CONVOY_SKIP_SWAP:-0}"
SKIP_ADMIN="${CONVOY_SKIP_ADMIN:-0}"

CURRENT_STEP="startup"
PACKAGE_MANAGER=""
PVE_VERSION=""
PVE_VERSION_RAW=""
PUBLIC_IPV4=""
DEFAULT_IPV4=""
PANEL_URL_IP=""
COMPOSE_MODE=""
SWAP_SCRIPT=""
TOKEN_FILE=""

CREATED_INSTALL_DIR=0
CREATED_SWAP=0
STARTED_COMPOSE=0
CREATED_PVE_TOKEN=0
EXTRACTED_BROKER=0

if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  BLUE="\033[36m"
  PLAIN="\033[0m"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  PLAIN=""
fi

say() {
  local color="$1"
  local level="$2"
  local en="$3"
  local zh="$4"
  printf "%b[%s]%b %s / %s\n" "$color" "$level" "$PLAIN" "$en" "$zh"
}

info() { say "$GREEN" "INFO" "$1" "$2"; }
warn() { say "$YELLOW" "WARN" "$1" "$2"; }
error() { say "$RED" "ERROR" "$1" "$2"; }
debug() { say "$BLUE" "STEP" "$1" "$2"; }

usage() {
  cat <<USAGE
Convoy Panel installer / Convoy Panel 安装脚本

Usage / 用法:
  bash $SCRIPT_NAME [options]

Options / 选项:
  --convoy-version VERSION   Pin Convoy Panel release, for example v2.0.3-beta or latest.
                             固定 Convoy Panel 版本，例如 v2.0.3-beta 或 latest。
  --broker-version VERSION   Pin Convoy Broker release, default: latest.
                             固定 Convoy Broker 版本，默认 latest。
  --install-dir DIR          Installation directory, default: /var/www/convoy.
                             安装目录，默认 /var/www/convoy。
  --force                    Continue when the install directory already has files.
                             安装目录已有文件时仍继续。
  --no-rollback              Keep created resources when installation fails.
                             安装失败时保留已创建资源。
  --skip-network-check       Skip GitHub, Docker Hub, and local PVE API reachability checks.
                             跳过 GitHub、Docker Hub 和本机 PVE API 连通性检查。
  --skip-swap                Do not create swap automatically when memory is low.
                             内存不足时不自动创建 swap。
  --skip-admin               Do not run the interactive admin creation command.
                             不运行交互式管理员创建命令。
  --help                     Show this help.
                             显示帮助。

Environment variables / 环境变量:
  CONVOY_VERSION, BROKER_VERSION, CONVOY_INSTALL_DIR, CONVOY_FORCE,
  CONVOY_SKIP_NETWORK_CHECK, CONVOY_SKIP_SWAP, CONVOY_SKIP_ADMIN,
  PVE_USERID, PVE_TOKEN_ID, ROLLBACK_ON_ERROR, CONVOY_LOG_DIR
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --convoy-version)
        [[ $# -ge 2 ]] || { error "Missing value for --convoy-version" "--convoy-version 缺少参数"; exit 2; }
        CONVOY_VERSION="$2"
        shift 2
        ;;
      --broker-version)
        [[ $# -ge 2 ]] || { error "Missing value for --broker-version" "--broker-version 缺少参数"; exit 2; }
        BROKER_VERSION="$2"
        shift 2
        ;;
      --install-dir)
        [[ $# -ge 2 ]] || { error "Missing value for --install-dir" "--install-dir 缺少参数"; exit 2; }
        CONVOY_INSTALL_DIR="$2"
        shift 2
        ;;
      --force)
        FORCE_INSTALL=1
        shift
        ;;
      --no-rollback)
        ROLLBACK_ON_ERROR=0
        shift
        ;;
      --skip-network-check)
        SKIP_NETWORK_CHECK=1
        shift
        ;;
      --skip-swap)
        SKIP_SWAP=1
        shift
        ;;
      --skip-admin)
        SKIP_ADMIN=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1" "未知选项：$1"
        usage
        exit 2
        ;;
    esac
  done
}

setup_locale() {
  local utf8_locale=""
  utf8_locale="$(locale -a 2>/dev/null | grep -i -m 1 -E "C\.UTF-8|C\.utf8|UTF-8|utf8" || true)"
  if [[ -n "$utf8_locale" ]]; then
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    info "Locale set to $utf8_locale" "已设置语言环境为 $utf8_locale"
  else
    warn "No UTF-8 locale was found; continuing with the current locale" "未找到 UTF-8 locale，将使用当前语言环境继续"
  fi
}

setup_logging() {
  mkdir -p "$LOG_DIR" "$STATE_DIR"
  chmod 700 "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Install log: $LOG_FILE" "安装日志：$LOG_FILE"
}

run_cmd() {
  local en="$1"
  local zh="$2"
  shift 2
  CURRENT_STEP="$en / $zh"
  debug "$en" "$zh"
  "$@"
  CURRENT_STEP="idle"
}

abort() {
  error "$1" "$2"
  exit "${3:-1}"
}

on_interrupt() {
  local exit_code=$?
  trap - ERR INT TERM
  set +e
  error "Installation interrupted during: $CURRENT_STEP" "安装在此步骤被中断：$CURRENT_STEP"
  rollback
  exit "$exit_code"
}

on_error() {
  local exit_code=$?
  local line="${BASH_LINENO[0]:-unknown}"
  trap - ERR INT TERM
  set +e
  error "Installation failed at line $line during: $CURRENT_STEP" "安装在第 $line 行失败，当前步骤：$CURRENT_STEP"
  error "See the full log at $LOG_FILE" "完整日志见 $LOG_FILE"
  rollback
  exit "$exit_code"
}

rollback() {
  if [[ "$ROLLBACK_ON_ERROR" != "1" ]]; then
    warn "Rollback is disabled; created resources are kept" "已禁用回滚，保留已创建资源"
    return
  fi

  warn "Starting rollback for resources created by this run" "开始回滚本次运行创建的资源"

  if [[ "$STARTED_COMPOSE" == "1" && -d "$CONVOY_INSTALL_DIR" ]]; then
    (
      cd "$CONVOY_INSTALL_DIR" 2>/dev/null || exit 0
      compose down -v --remove-orphans
    ) || true
  fi

  if [[ "$CREATED_PVE_TOKEN" == "1" ]]; then
    pveum user token remove "$PVE_USERID" "$PVE_TOKEN_ID" >/dev/null 2>&1 ||
      pveum user token delete "$PVE_USERID" "$PVE_TOKEN_ID" >/dev/null 2>&1 ||
      true
  fi

  if [[ "$CREATED_SWAP" == "1" && -n "$SWAP_SCRIPT" && -f "$SWAP_SCRIPT" ]]; then
    bash "$SWAP_SCRIPT" --delete || true
  fi

  if [[ "$CREATED_INSTALL_DIR" == "1" && -d "$CONVOY_INSTALL_DIR" ]]; then
    rm -rf "$CONVOY_INSTALL_DIR"
  fi

  if [[ "$EXTRACTED_BROKER" == "1" ]]; then
    warn "Broker files were extracted to / and are listed in $STATE_DIR/broker-files.txt; review before manual removal" "Broker 文件已解压到 /，清单在 $STATE_DIR/broker-files.txt，手动删除前请先核对"
  fi
}

check_root() {
  info "Checking root permissions" "检查 root 权限"
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || abort "Please run this script as root" "请使用 root 用户运行此脚本"
}

validate_install_dir() {
  CONVOY_INSTALL_DIR="${CONVOY_INSTALL_DIR%/}"
  [[ -n "$CONVOY_INSTALL_DIR" ]] || CONVOY_INSTALL_DIR="/"
  case "$CONVOY_INSTALL_DIR" in
    /|/var|/var/www|/root|/usr|/etc|/tmp)
      abort "Refusing unsafe install directory: $CONVOY_INSTALL_DIR" "拒绝使用高风险安装目录：$CONVOY_INSTALL_DIR"
      ;;
  esac
}

detect_platform() {
  local kernel os_id os_like os_version
  kernel="$(uname -s 2>/dev/null || printf unknown)"
  os_id=""
  os_like=""
  os_version=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
    os_version="${VERSION_ID:-}"
  fi

  info "Detected platform: kernel=$kernel id=${os_id:-unknown} version=${os_version:-unknown}" "检测到平台：内核=$kernel 发行版=${os_id:-unknown} 版本=${os_version:-unknown}"

  if [[ "$kernel" != "Linux" ]]; then
    abort "Convoy Panel requires Proxmox VE on Linux; this host is $kernel" "Convoy Panel 需要 Linux 上的 Proxmox VE；当前主机是 $kernel"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PACKAGE_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PACKAGE_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PACKAGE_MANAGER="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PACKAGE_MANAGER="pacman"
  elif command -v apk >/dev/null 2>&1; then
    PACKAGE_MANAGER="apk"
  elif command -v pkg >/dev/null 2>&1; then
    PACKAGE_MANAGER="pkg"
  else
    abort "No supported package manager was found" "未找到受支持的包管理器"
  fi
  info "Package manager: $PACKAGE_MANAGER" "包管理器：$PACKAGE_MANAGER"

  if [[ "$os_id" =~ (arch|alpine) || "$os_like" =~ (arch|alpine) ]]; then
    warn "This Linux distribution can run the diagnostics, but Convoy installation still requires Proxmox VE" "该 Linux 发行版可运行诊断，但 Convoy 安装仍要求 Proxmox VE"
  fi
}

version_ge() {
  local raw_a="${1%%-*}"
  local raw_b="${2%%-*}"
  local a_parts b_parts i a b
  raw_a="${raw_a%%+*}"
  raw_b="${raw_b%%+*}"
  IFS='.' read -r -a a_parts <<< "$raw_a"
  IFS='.' read -r -a b_parts <<< "$raw_b"
  for i in 0 1 2 3; do
    a="${a_parts[$i]:-0}"
    b="${b_parts[$i]:-0}"
    [[ "$a" =~ ^[0-9]+$ ]] || a=0
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    if ((10#$a > 10#$b)); then
      return 0
    fi
    if ((10#$a < 10#$b)); then
      return 1
    fi
  done
  return 0
}

check_pve() {
  info "Checking Proxmox VE version" "检查 Proxmox VE 版本"
  command -v pveversion >/dev/null 2>&1 || abort "PVE is not installed or pveversion is missing" "未安装 PVE 或缺少 pveversion"

  PVE_VERSION_RAW="$(pveversion | head -n 1)"
  PVE_VERSION="$(printf "%s" "$PVE_VERSION_RAW" | awk -F'/' '{print $2}' | awk '{print $1}')"
  PVE_VERSION="${PVE_VERSION:-0}"

  if ! version_ge "$PVE_VERSION" "$MIN_PVE_VERSION"; then
    abort "Unsupported PVE version $PVE_VERSION_RAW; minimum supported version is $MIN_PVE_VERSION" "不支持的 PVE 版本 $PVE_VERSION_RAW；最低支持版本为 $MIN_PVE_VERSION"
  fi

  info "PVE version is supported: $PVE_VERSION_RAW" "PVE 版本受支持：$PVE_VERSION_RAW"
  info "Convoy Panel release: $CONVOY_VERSION" "Convoy Panel 版本：$CONVOY_VERSION"
  info "Convoy Broker release: $BROKER_VERSION" "Convoy Broker 版本：$BROKER_VERSION"
}

check_existing_install() {
  if [[ -d "$CONVOY_INSTALL_DIR" ]] && find "$CONVOY_INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    if [[ "$FORCE_INSTALL" == "1" ]]; then
      warn "Existing installation directory is not empty; continuing because --force was used: $CONVOY_INSTALL_DIR" "安装目录非空，但已指定 --force，继续执行：$CONVOY_INSTALL_DIR"
    else
      abort "Existing installation directory is not empty: $CONVOY_INSTALL_DIR. Re-run with --force only if you intend to reuse or overwrite files." "安装目录非空：$CONVOY_INSTALL_DIR。如确认要复用或覆盖文件，请使用 --force 重新运行。"
    fi
  fi
}

package_update() {
  case "$PACKAGE_MANAGER" in
    apt)
      run_cmd "Updating apt metadata" "更新 apt 软件源" apt-get update
      run_cmd "Repairing broken apt dependencies" "修复 apt 依赖状态" env DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y
      ;;
    dnf)
      run_cmd "Refreshing dnf metadata" "刷新 dnf 软件源" dnf -y makecache
      ;;
    yum)
      run_cmd "Refreshing yum metadata" "刷新 yum 软件源" yum -y makecache
      ;;
    pacman)
      run_cmd "Refreshing pacman metadata" "刷新 pacman 软件源" pacman -Sy --noconfirm
      ;;
    apk)
      run_cmd "Refreshing apk metadata" "刷新 apk 软件源" apk update
      ;;
    pkg)
      run_cmd "Refreshing pkg metadata" "刷新 pkg 软件源" pkg update -f
      ;;
  esac
}

package_install() {
  local packages=("$@")
  case "$PACKAGE_MANAGER" in
    apt)
      env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    pacman)
      pacman -S --noconfirm --needed "${packages[@]}"
      ;;
    apk)
      apk add --no-cache "${packages[@]}"
      ;;
    pkg)
      pkg install -y "${packages[@]}"
      ;;
  esac
}

ensure_command() {
  local command_name="$1"
  local package_name="${2:-$1}"
  if command -v "$command_name" >/dev/null 2>&1; then
    return
  fi
  run_cmd "Installing dependency: $package_name" "安装依赖：$package_name" package_install "$package_name"
  command -v "$command_name" >/dev/null 2>&1 || abort "Required command is still missing after install: $command_name" "安装后仍缺少必要命令：$command_name"
}

install_required_tools() {
  ensure_command curl curl
  ensure_command tar tar
  ensure_command jq jq
  ensure_command openssl openssl
  ensure_command awk awk
  ensure_command sed sed
  ensure_command grep grep
}

get_cpu_cores() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
  elif [[ -r /proc/cpuinfo ]]; then
    grep -c '^processor' /proc/cpuinfo
  else
    printf "1"
  fi
}

get_total_memory_mb() {
  if command -v free >/dev/null 2>&1; then
    free -m | awk '/^Mem:/{print $2}'
  elif [[ -r /proc/meminfo ]]; then
    awk '/^MemTotal:/{printf "%d\n", $2 / 1024}' /proc/meminfo
  else
    printf "0"
  fi
}

get_total_swap_mb() {
  if command -v free >/dev/null 2>&1; then
    free -m | awk '/^Swap:/{print $2}'
  elif [[ -r /proc/meminfo ]]; then
    awk '/^SwapTotal:/{printf "%d\n", $2 / 1024}' /proc/meminfo
  else
    printf "0"
  fi
}

get_swapfile_mb() {
  if [[ -r /proc/swaps ]]; then
    awk '$1 == "/swapfile" {printf "%d\n", $3 / 1024}' /proc/swaps
  else
    printf "0"
  fi
}

find_existing_path_for_df() {
  local path="$1"
  while [[ ! -e "$path" && "$path" != "/" ]]; do
    path="$(dirname -- "$path")"
  done
  printf "%s" "$path"
}

available_disk_mb() {
  local path
  path="$(find_existing_path_for_df "$1")"
  local free_mb
  free_mb="$(df -Pm "$path" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  if [[ -z "$free_mb" ]]; then
    free_mb="$(df -Pk "$path" | awk 'NR==2 {printf "%d\n", $4 / 1024}')"
  fi
  printf "%s" "$free_mb"
}

require_disk_space_mb() {
  local path="$1"
  local required_mb="$2"
  local free_mb
  free_mb="$(available_disk_mb "$path")"
  [[ "$free_mb" =~ ^[0-9]+$ ]] || abort "Unable to determine free disk space for $path" "无法检测 $path 的可用磁盘空间"
  info "Free disk space at $path: ${free_mb} MiB" "$path 可用磁盘空间：${free_mb} MiB"
  if ((free_mb < required_mb)); then
    abort "At least ${required_mb} MiB free disk space is required at $path" "$path 至少需要 ${required_mb} MiB 可用磁盘空间"
  fi
}

locate_swap_script() {
  local candidate="$SCRIPT_DIR/build_swap.sh"
  if [[ -f "$candidate" ]]; then
    SWAP_SCRIPT="$candidate"
    return
  fi

  SWAP_SCRIPT="$STATE_DIR/build_swap.sh"
  run_cmd "Downloading build_swap.sh" "下载 build_swap.sh" curl -fL --connect-timeout 10 --retry 3 --retry-delay 2 \
    -o "$SWAP_SCRIPT" "https://raw.githubusercontent.com/oneclickvirt/convoypanel-scripts/main/build_swap.sh"
  chmod +x "$SWAP_SCRIPT"
}

check_resources() {
  info "Checking CPU, memory, swap, and disk requirements" "检查 CPU、内存、swap 和磁盘要求"

  local cpu_cores memory_mb swap_mb swapfile_mb other_swap_mb required_swap_mb total_memory_mb had_swapfile
  cpu_cores="$(get_cpu_cores)"
  [[ "$cpu_cores" =~ ^[0-9]+$ ]] || cpu_cores=1
  if ((cpu_cores < 2)); then
    abort "Minimum requirement not met: at least 2 CPU cores are required" "未满足最低要求：至少需要 2 个 CPU 核心"
  fi

  memory_mb="$(get_total_memory_mb)"
  swap_mb="$(get_total_swap_mb)"
  swapfile_mb="$(get_swapfile_mb)"
  [[ "$memory_mb" =~ ^[0-9]+$ ]] || memory_mb=0
  [[ "$swap_mb" =~ ^[0-9]+$ ]] || swap_mb=0
  [[ "$swapfile_mb" =~ ^[0-9]+$ ]] || swapfile_mb=0
  had_swapfile=0
  [[ -f /swapfile || "$swapfile_mb" -gt 0 ]] && had_swapfile=1
  other_swap_mb=$((swap_mb > swapfile_mb ? swap_mb - swapfile_mb : 0))
  total_memory_mb=$((memory_mb + swap_mb))

  info "CPU cores: $cpu_cores, memory: ${memory_mb} MiB, swap: ${swap_mb} MiB" "CPU 核心：$cpu_cores，内存：${memory_mb} MiB，swap：${swap_mb} MiB"

  if ((total_memory_mb < MIN_MEMORY_MB)); then
    if [[ "$SKIP_SWAP" == "1" ]]; then
      abort "Memory plus swap is below ${MIN_MEMORY_MB} MiB and swap creation is disabled" "内存加 swap 低于 ${MIN_MEMORY_MB} MiB，且已禁用自动创建 swap"
    fi
    required_swap_mb=$((MIN_MEMORY_MB - memory_mb - other_swap_mb))
    ((required_swap_mb < 512)) && required_swap_mb=512
    required_swap_mb=$((((required_swap_mb + 255) / 256) * 256))
    warn "Memory is low; creating /swapfile with ${required_swap_mb} MiB" "内存不足，将创建 ${required_swap_mb} MiB 的 /swapfile"
    locate_swap_script
    run_cmd "Creating swap with build_swap.sh" "使用 build_swap.sh 创建 swap" bash "$SWAP_SCRIPT" "$required_swap_mb"
    if [[ "$had_swapfile" == "0" ]]; then CREATED_SWAP=1; else warn "Existing /swapfile was replaced; rollback will not delete it" "检测到原有 /swapfile 已被替换，回滚时不会删除它"; fi

    memory_mb="$(get_total_memory_mb)"
    swap_mb="$(get_total_swap_mb)"
    total_memory_mb=$((memory_mb + swap_mb))
    if ((total_memory_mb < MIN_MEMORY_MB)); then
      abort "Memory plus swap is still below ${MIN_MEMORY_MB} MiB after swap creation" "创建 swap 后内存加 swap 仍低于 ${MIN_MEMORY_MB} MiB"
    fi
  fi

  require_disk_space_mb "/" "$MIN_DISK_MB"
  require_disk_space_mb "$CONVOY_INSTALL_DIR" "$MIN_DISK_MB"
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.' octets octet
  read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

detect_default_ipv4() {
  if command -v ip >/dev/null 2>&1; then
    DEFAULT_IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' || true)"
  fi
  if [[ -z "$DEFAULT_IPV4" ]] && command -v hostname >/dev/null 2>&1; then
    DEFAULT_IPV4="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [[ -z "$DEFAULT_IPV4" ]] && command -v ifconfig >/dev/null 2>&1; then
    DEFAULT_IPV4="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}' || true)"
  fi
  valid_ipv4 "$DEFAULT_IPV4" || DEFAULT_IPV4=""
}

detect_public_ipv4() {
  local apis=(
    "https://ip4.seeip.org"
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://api.my-ip.io/ip"
    "https://ip.sb"
    "https://ipget.net"
    "https://ip.ping0.cc"
  )
  local start elapsed api response
  start="$(date +%s)"
  for api in "${apis[@]}"; do
    elapsed=$(($(date +%s) - start))
    if ((elapsed >= 15)); then
      warn "IPv4 public API detection reached the 15 second overall timeout" "公网 IPv4 API 检测达到 15 秒总超时"
      break
    fi
    response="$(curl -fsS4 --connect-timeout 2 --max-time 3 "$api" 2>/dev/null | tr -d '[:space:]' || true)"
    if valid_ipv4 "$response"; then
      PUBLIC_IPV4="$response"
      info "Public IPv4 detected through $api: $PUBLIC_IPV4" "通过 $api 检测到公网 IPv4：$PUBLIC_IPV4"
      return
    fi
  done
}

check_ipv4() {
  info "Checking IPv4 addresses" "检查 IPv4 地址"
  detect_default_ipv4
  detect_public_ipv4
  if [[ -z "$DEFAULT_IPV4" && -z "$PUBLIC_IPV4" ]]; then
    abort "The host must have an IPv4 address" "主机必须具备 IPv4 地址"
  fi
  PANEL_URL_IP="${PUBLIC_IPV4:-$DEFAULT_IPV4}"
  info "Default-route IPv4: ${DEFAULT_IPV4:-not detected}" "默认路由 IPv4：${DEFAULT_IPV4:-未检测到}"
  info "Panel URL IPv4: $PANEL_URL_IP" "面板访问 IPv4：$PANEL_URL_IP"
}

check_endpoint() {
  local name="$1"
  local url="$2"
  local allow_auth_error="${3:-0}"
  local http_code
  http_code="$(curl -k -L -sS --connect-timeout 5 --max-time 12 -o /dev/null -w "%{http_code}" "$url" || printf "000")"
  if [[ "$http_code" =~ ^(2|3)[0-9][0-9]$ || ( "$allow_auth_error" == "1" && "$http_code" =~ ^40(1|3)$ ) ]]; then
    info "$name reachable with HTTP $http_code" "$name 可达，HTTP $http_code"
    return
  fi
  error "$name is not reachable or returned HTTP $http_code: $url" "$name 不可达或返回 HTTP $http_code：$url"
  return 1
}

network_preflight() {
  if [[ "$SKIP_NETWORK_CHECK" == "1" ]]; then
    warn "Network preflight checks are skipped" "已跳过网络预检"
    return
  fi

  info "Checking network reachability for GitHub, Docker Hub, and local PVE API" "检查 GitHub、Docker Hub 和本机 PVE API 连通性"
  check_endpoint "GitHub" "https://github.com"
  check_endpoint "Convoy Panel releases" "https://github.com/convoypanel/panel/releases/${CONVOY_VERSION}/download/panel.tar.gz"
  check_endpoint "Docker Hub registry" "https://registry-1.docker.io/v2/" 1
  check_endpoint "Local PVE API" "https://127.0.0.1:8006/api2/json/version"
}

docker_package_name() {
  case "$PACKAGE_MANAGER" in
    apt) printf "docker.io" ;;
    dnf|yum|pacman|apk) printf "docker" ;;
    pkg) printf "docker" ;;
  esac
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    local docker_package
    docker_package="$(docker_package_name)"
    run_cmd "Installing Docker package: $docker_package" "安装 Docker 包：$docker_package" package_install "$docker_package"
  fi
  command -v docker >/dev/null 2>&1 || abort "Docker command is not available after installation" "安装后仍找不到 docker 命令"
}

start_and_verify_docker() {
  info "Starting and verifying Docker service" "启动并验证 Docker 服务"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker
    systemctl start docker
  elif command -v service >/dev/null 2>&1; then
    service docker start
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service docker start
  else
    warn "No known service manager was found; Docker must already be running" "未找到已知服务管理器，Docker 需要已处于运行状态"
  fi

  local attempt
  for ((attempt = 1; attempt <= 12; attempt++)); do
    if docker info >/dev/null 2>&1; then
      info "Docker daemon is running" "Docker 守护进程已正常运行"
      return
    fi
    sleep 5
  done
  abort "Docker daemon did not become ready within 60 seconds" "Docker 守护进程 60 秒内未就绪"
}

map_compose_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf "x86_64" ;;
    aarch64|arm64) printf "aarch64" ;;
    armv7l) printf "armv7" ;;
    armv6l) printf "armv6" ;;
    *) return 1 ;;
  esac
}

ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_MODE="plugin"
    info "Using Docker Compose plugin: docker compose" "使用 Docker Compose 插件：docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_MODE="standalone"
    info "Using Docker Compose standalone binary: docker-compose" "使用 Docker Compose 独立二进制：docker-compose"
    return
  fi

  local arch compose_url
  arch="$(map_compose_arch)" || abort "Architecture is not supported by Docker Compose binary installer: $(uname -m)" "Docker Compose 二进制安装器不支持当前架构：$(uname -m)"
  compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch"
  run_cmd "Installing latest stable Docker Compose binary" "安装最新稳定 Docker Compose 二进制" curl -fL --connect-timeout 10 --retry 3 --retry-delay 2 \
    -o /usr/local/bin/docker-compose "$compose_url"
  chmod +x /usr/local/bin/docker-compose
  docker-compose version
  COMPOSE_MODE="standalone"
}

compose() {
  if [[ "$COMPOSE_MODE" == "plugin" ]]; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

check_security_modules() {
  info "Checking AppArmor and SELinux state" "检查 AppArmor 和 SELinux 状态"

  if [[ -f /usr/local/bin/apparmor.txt || -d /sys/kernel/security/apparmor || -d /sys/module/apparmor ]]; then
    if ! command -v aa-status >/dev/null 2>&1 && [[ "$PACKAGE_MANAGER" == "apt" ]]; then
      run_cmd "Installing AppArmor tools" "安装 AppArmor 工具" package_install apparmor
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files apparmor.service >/dev/null 2>&1; then
      systemctl enable apparmor.service || true
      systemctl start apparmor.service || true
    fi
    if command -v modprobe >/dev/null 2>&1 && ! lsmod 2>/dev/null | grep -q apparmor; then
      modprobe apparmor || warn "Unable to load AppArmor module automatically" "无法自动加载 AppArmor 内核模块"
    fi
    printf "1\n" >/usr/local/bin/apparmor.txt
    info "AppArmor compatibility check completed" "AppArmor 兼容性检查完成"
  else
    info "AppArmor marker or module was not detected" "未检测到 AppArmor 标记或模块"
  fi

  local selinux_mode=""
  if command -v getenforce >/dev/null 2>&1; then
    selinux_mode="$(getenforce 2>/dev/null || true)"
  elif [[ -r /sys/fs/selinux/enforce ]]; then
    selinux_mode="$(awk '{print $1 == 1 ? "Enforcing" : "Permissive"}' /sys/fs/selinux/enforce)"
  fi
  if [[ "$selinux_mode" == "Enforcing" ]]; then
    warn "SELinux is Enforcing. Docker volumes may need a site-specific SELinux policy if containers cannot access mounted files." "SELinux 处于 Enforcing。若容器无法访问挂载文件，可能需要站点自定义 SELinux 策略。"
  elif [[ -n "$selinux_mode" ]]; then
    info "SELinux mode: $selinux_mode" "SELinux 模式：$selinux_mode"
  else
    info "SELinux was not detected" "未检测到 SELinux"
  fi
}

release_asset_url() {
  local repo="$1"
  local version="$2"
  local asset="$3"
  printf "https://github.com/%s/releases/%s/download/%s" "$repo" "$version" "$asset"
}

download_file() {
  local url="$1"
  local destination="$2"
  local en="$3"
  local zh="$4"
  run_cmd "$en" "$zh" curl -fL --connect-timeout 10 --retry 3 --retry-delay 2 -o "$destination" "$url"
}

prepare_install_dir() {
  if [[ ! -d "$CONVOY_INSTALL_DIR" ]]; then
    run_cmd "Creating install directory: $CONVOY_INSTALL_DIR" "创建安装目录：$CONVOY_INSTALL_DIR" mkdir -p "$CONVOY_INSTALL_DIR"
    CREATED_INSTALL_DIR=1
  elif ! find "$CONVOY_INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then CREATED_INSTALL_DIR=1
  fi
  cd "$CONVOY_INSTALL_DIR"
}

extract_panel() {
  local panel_url
  panel_url="$(release_asset_url "convoypanel/panel" "$CONVOY_VERSION" "panel.tar.gz")"
  require_disk_space_mb "$CONVOY_INSTALL_DIR" "$MIN_DISK_MB"
  download_file "$panel_url" "$CONVOY_INSTALL_DIR/panel.tar.gz" "Downloading Convoy Panel archive" "下载 Convoy Panel 压缩包"
  run_cmd "Validating Convoy Panel archive" "校验 Convoy Panel 压缩包" tar -tzf "$CONVOY_INSTALL_DIR/panel.tar.gz"
  run_cmd "Extracting Convoy Panel archive" "解压 Convoy Panel 压缩包" tar -xzvf "$CONVOY_INSTALL_DIR/panel.tar.gz" -C "$CONVOY_INSTALL_DIR"
}

make_random_secret() {
  openssl rand -base64 16 | tr -d '\n'
}

make_random_identifier() {
  printf "convoy_%s" "$(openssl rand -hex 6)"
}

dotenv_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

set_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp "$STATE_DIR/env.XXXXXX")"
  awk -v key="$key" -v line="$key=$value" '
    BEGIN { found = 0 }
    $0 ~ "^" key "=" { print line; found = 1; next }
    { print }
    END { if (found == 0) print line }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

configure_env() {
  cd "$CONVOY_INSTALL_DIR"
  [[ -f .env.example ]] || abort "Missing .env.example in Convoy Panel archive" "Convoy Panel 压缩包中缺少 .env.example"
  if [[ ! -f .env ]]; then
    run_cmd "Creating .env from .env.example" "基于 .env.example 创建 .env" cp .env.example .env
  fi

  local db_database db_username db_password db_root_password redis_password
  db_database="$(make_random_identifier)"
  db_username="$(make_random_identifier)"
  db_password="$(make_random_secret)"
  db_root_password="$(make_random_secret)"
  redis_password="$(make_random_secret)"

  set_env_var .env DB_DATABASE "$db_database"
  set_env_var .env DB_USERNAME "$db_username"
  set_env_var .env DB_PASSWORD "$(dotenv_quote "$db_password")"
  set_env_var .env DB_ROOT_PASSWORD "$(dotenv_quote "$db_root_password")"
  set_env_var .env REDIS_PASSWORD "$(dotenv_quote "$redis_password")"

  chmod 600 .env
  info "Generated strong database and Redis secrets with openssl rand -base64 16; values are stored in .env and not printed" "已用 openssl rand -base64 16 生成强数据库和 Redis 密码；值已写入 .env，不在终端输出"
}

fix_permissions() {
  cd "$CONVOY_INSTALL_DIR"
  if [[ -d storage ]]; then
    run_cmd "Setting storage permissions" "设置 storage 权限" chmod -R o+w storage
  fi
  if [[ -d bootstrap/cache ]]; then
    run_cmd "Setting bootstrap/cache permissions" "设置 bootstrap/cache 权限" chmod -R o+w bootstrap/cache
  fi
}

start_containers() {
  cd "$CONVOY_INSTALL_DIR"
  require_disk_space_mb "$CONVOY_INSTALL_DIR" "$MIN_DISK_MB"
  run_cmd "Starting Convoy containers" "启动 Convoy 容器" compose up -d
  STARTED_COMPOSE=1
  run_cmd "Listing Convoy containers" "列出 Convoy 容器" compose ps
}

install_broker() {
  local broker_url broker_archive
  broker_url="$(release_asset_url "convoypanel/broker" "$BROKER_VERSION" "broker.tar.gz")"
  broker_archive="$STATE_DIR/broker.tar.gz"
  require_disk_space_mb "/" 1024
  download_file "$broker_url" "$broker_archive" "Downloading Convoy Broker archive" "下载 Convoy Broker 压缩包"
  run_cmd "Validating Convoy Broker archive" "校验 Convoy Broker 压缩包" tar -tzf "$broker_archive"
  tar -tzf "$broker_archive" >"$STATE_DIR/broker-files.txt"
  run_cmd "Extracting Convoy Broker archive to /" "将 Convoy Broker 解压到 /" tar -xzvf "$broker_archive" -C /
  EXTRACTED_BROKER=1
}

build_application() {
  cd "$CONVOY_INSTALL_DIR"
  require_disk_space_mb "$CONVOY_INSTALL_DIR" 2048
  run_cmd "Installing PHP and Node dependencies with lock files when available" "优先使用 lock 文件安装 PHP 和 Node 依赖" compose exec -T workspace bash -lc '
    set -Eeuo pipefail
    if [ -f composer.lock ]; then
      composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction
    else
      echo "composer.lock was not found; falling back to composer install without a lock file"
      composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction
    fi
    if [ -f package-lock.json ]; then
      npm ci
    else
      echo "package-lock.json was not found; falling back to npm install"
      npm install
    fi
    npm run build
  '
}

run_artisan_setup() {
  cd "$CONVOY_INSTALL_DIR"
  run_cmd "Generating app key and optimizing Laravel" "生成应用密钥并优化 Laravel" compose exec -T workspace bash -lc 'php artisan key:generate --force && php artisan optimize'
  run_cmd "Running database migrations" "运行数据库迁移" compose exec -T workspace php artisan migrate --force
}

create_pve_token() {
  info "Creating PVE API token for Convoy" "为 Convoy 创建 PVE API Token"
  command -v pveum >/dev/null 2>&1 || abort "pveum command is missing" "缺少 pveum 命令"
  command -v jq >/dev/null 2>&1 || abort "jq command is missing" "缺少 jq 命令"

  local token_json token_value full_token_id
  token_json="$(pveum user token add "$PVE_USERID" "$PVE_TOKEN_ID" --privsep=0 --output-format=json)"
  CREATED_PVE_TOKEN=1
  if ! token_value="$(printf "%s" "$token_json" | jq -er '.value // empty')"; then
    error "pveum output does not contain a valid value field" "pveum 输出缺少有效的 value 字段"
    return 1
  fi
  if ! full_token_id="$(printf "%s" "$token_json" | jq -er '."full-tokenid" // empty')"; then
    error "pveum output does not contain a valid full-tokenid field" "pveum 输出缺少有效的 full-tokenid 字段"
    return 1
  fi
  if [[ -z "$token_value" || "$token_value" == "null" || -z "$full_token_id" || "$full_token_id" == "null" ]]; then
    error "pveum did not return a valid token value and full-tokenid" "pveum 未返回有效的 token value 和 full-tokenid"
    return 1
  fi

  TOKEN_FILE="/root/convoy-pve-token-$TIMESTAMP.txt"
  umask 077
  {
    printf "PVE Version: %s\n" "$PVE_VERSION"
    printf "Token ID: %s\n" "$full_token_id"
    printf "Secret: %s\n" "$token_value"
    printf "Panel URL: http://%s:80/admin/nodes\n" "$PANEL_URL_IP"
    printf "Guide: https://convoypanel.com/docs/panel/adding-a-node.html#adding-the-node-in-convoy\n"
  } >"$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  info "PVE token was created and saved to $TOKEN_FILE with mode 600" "PVE Token 已创建并以 600 权限保存到 $TOKEN_FILE"
}

create_admin_user() {
  cd "$CONVOY_INSTALL_DIR"
  if [[ "$SKIP_ADMIN" == "1" ]]; then
    warn "Skipping admin user creation because --skip-admin was used" "已按 --skip-admin 跳过管理员创建"
    return
  fi

  if [[ -t 0 && -t 1 ]]; then
    run_cmd "Creating Convoy administrator" "创建 Convoy 管理员" compose exec workspace php artisan c:user:make
  else
    warn "Non-interactive terminal detected; skipping php artisan c:user:make. Run it manually inside the workspace container after install." "检测到非交互终端，跳过 php artisan c:user:make。安装后请手动在 workspace 容器中运行。"
  fi
}

print_success() {
  info "Convoy Panel installation completed" "Convoy Panel 安装完成"
  info "Open Panel URL: http://$PANEL_URL_IP:80" "面板访问地址：http://$PANEL_URL_IP:80"
  if [[ -n "$DEFAULT_IPV4" && "$DEFAULT_IPV4" != "$PANEL_URL_IP" ]]; then
    info "Default-route local URL: http://$DEFAULT_IPV4:80" "默认路由本机地址：http://$DEFAULT_IPV4:80"
  fi
  if [[ -n "$TOKEN_FILE" ]]; then
    info "PVE node token file: $TOKEN_FILE" "PVE 节点 Token 文件：$TOKEN_FILE"
  fi
  info "Documentation: https://docs.convoypanel.com/" "文档：https://docs.convoypanel.com/"
  info "Install log: $LOG_FILE" "安装日志：$LOG_FILE"
}

main() {
  parse_args "$@"
  setup_locale
  check_root
  setup_logging
  trap on_error ERR
  trap on_interrupt INT TERM

  detect_platform
  validate_install_dir
  check_existing_install
  package_update
  install_required_tools
  check_pve
  check_resources
  check_ipv4
  network_preflight
  check_docker
  start_and_verify_docker
  ensure_docker_compose
  check_security_modules
  prepare_install_dir
  extract_panel
  fix_permissions
  configure_env
  start_containers
  install_broker
  build_application
  run_artisan_setup
  create_pve_token
  create_admin_user
  print_success
}

main "$@"
