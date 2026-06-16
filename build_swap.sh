#!/usr/bin/env bash
# by https://github.com/oneclickvirt/convoypanel-scripts
# Usage: bash build_swap.sh <size-in-MiB>

set -Eeuo pipefail

if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  PLAIN="\033[0m"
else
  GREEN=""
  RED=""
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
Swap helper / Swap 辅助脚本

Usage / 用法:
  bash build_swap.sh <size-in-MiB>
  bash build_swap.sh --delete

Examples / 示例:
  bash build_swap.sh 2048
  bash build_swap.sh --delete
USAGE
}

setup_locale() {
  local utf8_locale
  utf8_locale="$(locale -a 2>/dev/null | grep -i -m 1 -E "C\.UTF-8|C\.utf8|UTF-8|utf8" || true)"
  if [[ -n "$utf8_locale" ]]; then
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
  fi
}

check_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "This script must be run as root" "此脚本必须以 root 用户运行"
}

check_linux() {
  [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]] || fail "Swap creation is supported only on Linux" "仅支持在 Linux 上创建 swap"
  [[ -d /proc/vz ]] && fail "OpenVZ containers do not support this swap setup" "OpenVZ 容器不支持此 swap 设置"
}

remove_swapfile_from_fstab() {
  [[ -f /etc/fstab ]] || return
  local tmp
  tmp="$(mktemp)"
  awk '$1 != "/swapfile" { print }' /etc/fstab >"$tmp"
  cat "$tmp" >/etc/fstab
  rm -f "$tmp"
}

delete_swapfile() {
  if [[ -f /swapfile ]]; then
    info "Disabling /swapfile if active" "如果 /swapfile 处于启用状态则停用"
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
  else
    warn "/swapfile does not exist" "/swapfile 不存在"
  fi
  remove_swapfile_from_fstab
  info "Swapfile cleanup completed" "Swapfile 清理完成"
}

create_swapfile() {
  local swapsize="$1"
  [[ "$swapsize" =~ ^[0-9]+$ ]] || fail "Swap size must be a positive integer in MiB" "Swap 大小必须是 MiB 单位的正整数"
  ((swapsize >= 128)) || fail "Swap size must be at least 128 MiB" "Swap 大小至少需要 128 MiB"

  delete_swapfile
  info "Creating /swapfile with ${swapsize} MiB" "创建 ${swapsize} MiB 的 /swapfile"
  if ! fallocate -l "${swapsize}M" /swapfile 2>/dev/null; then
    warn "fallocate failed; falling back to dd" "fallocate 失败，改用 dd"
    dd if=/dev/zero of=/swapfile bs=1M count="$swapsize"
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -Eq '^[[:space:]]*/swapfile[[:space:]]+' /etc/fstab 2>/dev/null; then
    printf "/swapfile none swap defaults 0 0\n" >>/etc/fstab
  fi
  info "Swap was created successfully" "Swap 创建成功"
  cat /proc/swaps
  grep '^Swap' /proc/meminfo || true
}

main() {
  setup_locale
  if [[ $# -ne 1 ]]; then
    usage
    exit 2
  fi
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --delete)
      check_root
      check_linux
      delete_swapfile
      ;;
    *)
      check_root
      check_linux
      create_swapfile "$1"
      ;;
  esac
}

main "$@"
