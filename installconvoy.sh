#!/usr/bin/env bash
# by spiritlhl
# from https://github.com/spiritLHLS/convoypanel-scripts


ecsspeednetver="2023/04/04"
spver="1.2.0"
SERVER_BASE_URL="https://raw.githubusercontent.com/spiritLHLS/speedtest.net-CN-ID/main"
cd /root >/dev/null 2>&1
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch")
PACKAGE_UPDATE=("! apt-get update && apt-get --fix-broken install -y && apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy")
PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install" "pacman -Sy --noconfirm --needed")
PACKAGE_REMOVE=("apt-get -y remove" "apt-get -y remove" "yum -y remove" "yum -y remove" "yum -y remove" "pacman -Rsc --noconfirm")
PACKAGE_UNINSTALL=("apt-get -y autoremove" "apt-get -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)") 
SYS="${CMD[0]}"
[[ -n $SYS ]] || exit 1
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done
apt-get --fix-broken install -y > /dev/null 2>&1

checkroot(){
    _yellow "checking root"
	  [[ $EUID -ne 0 ]] && echo -e "${RED}Please use root to run this script. ${PLAIN}" && exit 1
}

checksystem(){
    if [[ "$SYSTEM" == "Ubuntu" ]]; then
        if [[ "$(lsb_release -rs)" == "20.04" || "$(lsb_release -rs)" == "22.04" ]]; then
            return
        fi
    fi
    _red "Error: Not support system, please check https://docs.convoypanel.com/guide/deployment"
    exit 1
}

checksystem2(){
    # Check CPU core count
    cpu_cores=$(grep -c ^processor /proc/cpuinfo)
    if [[ $cpu_cores -lt 2 ]]; then
    echo "Error: Minimum requirement not met. CPU core count should be at least 2."
    exit 1
    fi

    # Check available memory + swap
    available_memory=$(free -m | awk '/^Mem:/{print $2}')
    available_swap=$(free -m | awk '/^Swap:/{print $2}')
    if [[ -n $available_swap ]]; then
    if [[ $((available_memory + available_swap)) -lt 4000 ]]; then 
        _red "Error: Minimum requirement not met. Available memory + swap should be at least 4 GiB."
        exit 1
    fi
    else
    if [[ $available_memory -lt 4000 ]]; then
        _red "Error: Minimum requirement not met. Available memory should be at least 4 GiB."
        exit 1
    fi
    fi

    # Check available disk space
    disk_space=$(df -P / | awk '/^\/dev\//{print $4}')
    if [[ $disk_space -lt 10000 ]]; then
        _red "Error: Minimum requirement not met. Available disk space should be at least 10 GiB."
        exit 1
    fi
}

checkconvoy(){
    pve_version=$(pveversion)
    if [ $? -ne 0 ]; then
        _red "PVE is not installed"
        exit 1
    else
        _green "PVE version is: $pve_version"
    fi
    if [[ $pve_version == "7.2-7" ]]; then
        convoy_version="2.0.3-beta"
    elif [[ $pve_version == "7.3-4" || $pve_version > "7.3-4" ]]; then
        convoy_version="later"
    else
        _red "Error: Not support Proxmox Versions, please check https://docs.convoypanel.com/guide/deployment"
        exit 1
    fi
    _green "Convoy version: $convoy_version"
}


checkroot
checksystem
checksystem2
checkconvoy
_green "All minimum requirements are met."
