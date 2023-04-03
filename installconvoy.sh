#!/usr/bin/env bash
# by spiritlhl
# from https://github.com/spiritLHLS/convoypanel-scripts

cd /root >/dev/null 2>&1
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
	[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 用户运行本脚本！${PLAIN}" && exit 1
}

checkupdate(){
	    _yellow "Updating package management sources"
		  ${PACKAGE_UPDATE[int]} > /dev/null 2>&1
}

check_ipv4(){
  API_NET=("ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
  for p in "${API_NET[@]}"; do
    response=$(curl -s4m8 "$p")
    sleep 1
    if [ $? -eq 0 ] && ! echo "$response" | grep -q "error"; then
      IP_API="$p"
      break
    fi
  done
  ! curl -s4m8 $IP_API | grep -q '\.' && red " ERROR：The host must have IPv4. " && exit 1
}

checksystem(){
    if [[ "$SYSTEM" == "Ubuntu" || "$SYSTEM" == "Debian" ]]; then
        if [[ "$(lsb_release -rs)" == "20.04" || "$(lsb_release -rs)" == "22.04" || "$(lsb_release -rs)" == "11" ]]; then
            return
        fi
    fi
    _red "Error: Not support system, please check https://docs.convoypanel.com/guide/deployment"
    exit 1
}

check_docker(){
  if ! systemctl is-active docker >/dev/null 2>&1; then
      echo -e " \n Install docker \n " 
      ${PACKAGE_INSTALL[int]} docker.io
  fi
}

check_docker_compose(){
  if ! command -v docker-compose >/dev/null 2>&1; then
      _green "\n Install Docker Compose \n"
      COMPOSE_URL=""
      SYSTEM_ARCH=$(uname -m)
      case $SYSTEM_ARCH in
        "x86_64") COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.17.2/docker-compose-linux-x86_64" ;;
        "aarch64") COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.17.2/docker-compose-linux-arm64" ;;
        "armv6l") COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.17.2/docker-compose-linux-armhf" ;;
        "armv7l") COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.17.2/docker-compose-linux-armhf" ;;
        *) _red "\nArchitecture not supported for binary installation of Docker Compose.\n"; exit 1 ;;
      esac
      curl -SL $COMPOSE_URL -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
   fi
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

reload_apparmor(){
  ${PACKAGE_INSTALL[int]} apparmor-utils
  aa-status
  /etc/init.d/apparmor reload
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
        convoy_version="v2.0.3-beta"
    elif [[ $pve_version == "7.3-4" || $pve_version > "7.3-4" ]]; then
        convoy_version="latest"
    else
        _red "Error: Not support Proxmox Versions, please check https://docs.convoypanel.com/guide/deployment"
        exit 1
    fi
    _green "Convoy version: $convoy_version"
}


checkroot
checkupdate
reload_apparmor
check_ipv4
check_docker
check_docker_compose
checksystem
checksystem2
checkconvoy
_green "All minimum requirements are met."
if [ ! -d "/var/www/convoy" ]; then
  mkdir -p /var/www/convoy
fi
cd /var/www/convoy
if [ ! -f "panel.tar.gz" ]; then
  curl -Lo panel.tar.gz "https://github.com/convoypanel/panel/releases/${convoy_version}/download/panel.tar.gz"
fi
if [ -f "panel.tar.gz" ]; then
  tar -xzvf panel.tar.gz
fi
if [ -d "storage" ]; then
  chmod -R o+w storage/*
fi
if [ -d "bootstrap/cache" ]; then
  chmod -R o+w bootstrap/cache/
fi
if [ ! -f ".env" ]; then
  cp .env.example .env
fi
random_str1=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
random_str2=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
random_str3=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
random_str4=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
random_str5=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
sed -i "s/DB_DATABASE=convoy/DB_DATABASE=$random_str1/g" .env
sed -i "s/DB_USERNAME=convoy_user/DB_USERNAME=$random_str2/g" .env
sed -i "s/DB_PASSWORD=/DB_PASSWORD=$random_str3/g" .env
sed -i "s/DB_ROOT_PASSWORD=/DB_ROOT_PASSWORD=$random_str4/g" .env
sed -i "s/REDIS_PASSWORD=null/REDIS_PASSWORD=$random_str5/g" .env
_green "Now DB_DATABASE=$random_str1"
_green "Now DB_USERNAME=$random_str2"
_green "Now DB_PASSWORD=$random_str3"
_green "Now DB_ROOT_PASSWORD=$random_str4"
_green "Now REDIS_PASSWORD=$random_str5"
docker-compose up -d
# docker-compose exec workspace bash -c "composer install --no-dev --optimize-autoloader && npm install && npm run build"
