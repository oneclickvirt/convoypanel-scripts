#!/usr/bin/env bash
# Clean Convoy Panel uninstall helper.

set -Eeuo pipefail

CONVOY_INSTALL_DIR="${CONVOY_INSTALL_DIR:-/var/www/convoy}"
PVE_USERID="${PVE_USERID:-root@pam}"
PVE_TOKEN_ID="${PVE_TOKEN_ID:-convoy}"
REMOVE_IMAGES=0
REMOVE_LOGS=0
ASSUME_YES="${CONVOY_UNINSTALL_YES:-0}"
COMPOSE_MODE=""

if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  PLAIN="\033[0m"
else
  RED=""
  GREEN=""
  YELLOW=""
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
fail() {
  say "$RED" "ERROR" "$1" "$2"
  exit 1
}

usage() {
  cat <<USAGE
Convoy Panel uninstaller / Convoy Panel 卸载脚本

Usage / 用法:
  bash uninstallconvoy.sh --yes [options]

Options / 选项:
  --yes              Confirm removal without an interactive prompt.
                     非交互确认删除。
  --install-dir DIR  Installation directory, default: /var/www/convoy.
                     安装目录，默认 /var/www/convoy。
  --remove-images    Also remove local Compose images for this project.
                     同时删除本项目 Compose 本地镜像。
  --remove-logs      Remove installer logs under /var/log/convoypanel-scripts.
                     删除 /var/log/convoypanel-scripts 下的安装日志。
  --pve-user USER    PVE user that owns the token, default: root@pam.
                     PVE Token 所属用户，默认 root@pam。
  --pve-token ID     PVE token id to remove, default: convoy.
                     要删除的 PVE Token ID，默认 convoy。
  --help             Show this help.
                     显示帮助。
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        ASSUME_YES=1
        shift
        ;;
      --install-dir)
        [[ $# -ge 2 ]] || fail "Missing value for --install-dir" "--install-dir 缺少参数"
        CONVOY_INSTALL_DIR="$2"
        shift 2
        ;;
      --remove-images)
        REMOVE_IMAGES=1
        shift
        ;;
      --remove-logs)
        REMOVE_LOGS=1
        shift
        ;;
      --pve-user)
        [[ $# -ge 2 ]] || fail "Missing value for --pve-user" "--pve-user 缺少参数"
        PVE_USERID="$2"
        shift 2
        ;;
      --pve-token)
        [[ $# -ge 2 ]] || fail "Missing value for --pve-token" "--pve-token 缺少参数"
        PVE_TOKEN_ID="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1" "未知选项：$1"
        ;;
    esac
  done
}

check_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "This script must be run as root" "此脚本必须以 root 用户运行"
}

validate_install_dir() {
  CONVOY_INSTALL_DIR="${CONVOY_INSTALL_DIR%/}"
  [[ -n "$CONVOY_INSTALL_DIR" ]] || CONVOY_INSTALL_DIR="/"
  case "$CONVOY_INSTALL_DIR" in
    /|/var|/var/www|/root|/usr|/etc|/tmp)
      fail "Refusing unsafe install directory: $CONVOY_INSTALL_DIR" "拒绝使用高风险安装目录：$CONVOY_INSTALL_DIR"
      ;;
  esac
}

confirm() {
  if [[ "$ASSUME_YES" == "1" ]]; then
    return
  fi
  if [[ -t 0 ]]; then
    local answer
    printf "Remove Convoy Panel from %s? Type yes to continue / 是否从 %s 删除 Convoy Panel？输入 yes 继续: " "$CONVOY_INSTALL_DIR" "$CONVOY_INSTALL_DIR"
    read -r answer
    [[ "$answer" == "yes" ]] || fail "Uninstall cancelled" "已取消卸载"
  else
    fail "Non-interactive uninstall requires --yes" "非交互卸载需要 --yes"
  fi
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_MODE="plugin"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_MODE="standalone"
  else
    COMPOSE_MODE=""
  fi
}

compose() {
  if [[ "$COMPOSE_MODE" == "plugin" ]]; then
    docker compose "$@"
  elif [[ "$COMPOSE_MODE" == "standalone" ]]; then
    docker-compose "$@"
  else
    return 127
  fi
}

remove_containers() {
  if [[ ! -d "$CONVOY_INSTALL_DIR" ]]; then
    warn "Install directory does not exist: $CONVOY_INSTALL_DIR" "安装目录不存在：$CONVOY_INSTALL_DIR"
    return
  fi
  detect_compose
  if [[ -z "$COMPOSE_MODE" ]]; then
    warn "Docker Compose was not found; skipping container cleanup" "未找到 Docker Compose，跳过容器清理"
    return
  fi
  (
    cd "$CONVOY_INSTALL_DIR"
    if [[ "$REMOVE_IMAGES" == "1" ]]; then
      compose down -v --remove-orphans --rmi local
    else
      compose down -v --remove-orphans
    fi
  )
}

remove_pve_token() {
  if command -v pveum >/dev/null 2>&1; then
    pveum user token remove "$PVE_USERID" "$PVE_TOKEN_ID" >/dev/null 2>&1 ||
      pveum user token delete "$PVE_USERID" "$PVE_TOKEN_ID" >/dev/null 2>&1 ||
      warn "PVE token was not removed or did not exist: ${PVE_USERID}!${PVE_TOKEN_ID}" "PVE Token 未删除或不存在：${PVE_USERID}!${PVE_TOKEN_ID}"
  else
    warn "pveum was not found; skipping PVE token cleanup" "未找到 pveum，跳过 PVE Token 清理"
  fi
}

remove_files() {
  rm -rf "$CONVOY_INSTALL_DIR"
  if [[ "$REMOVE_LOGS" == "1" ]]; then
    rm -rf /var/log/convoypanel-scripts
  fi
}

main() {
  parse_args "$@"
  check_root
  validate_install_dir
  confirm
  info "Stopping containers and removing volumes" "停止容器并删除卷"
  remove_containers
  info "Removing PVE token if present" "如存在则删除 PVE Token"
  remove_pve_token
  info "Removing installation files" "删除安装文件"
  remove_files
  info "Uninstall completed" "卸载完成"
}

main "$@"
