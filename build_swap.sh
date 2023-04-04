#!/usr/bin/env bash
# by https://github.com/spiritLHLS/convoypanel-scripts
#./build_swap.sh Memory size (in MB)

swapsize="$1"

Green="\033[32m"
Font="\033[0m"
Red="\033[31m" 

#root权限
root_need(){
    if [[ $EUID -ne 0 ]]; then
        echo -e "${Red}Error:This script must be run as root!${Font}"
        exit 1
    fi
}


ovz_no(){
    if [[ -d "/proc/vz" ]]; then
        echo -e "${Red}Your VPS is based on OpenVZ，not supported!${Font}"
        exit 1
    fi
}

add_swap(){
  grep -q "swapfile" /etc/fstab

  if [ $? -ne 0 ]; then
    echo -e "${Green}swapfile not found, swapfile being created for it${Font}"
    fallocate -l ${swapsize}M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap defaults 0 0' >> /etc/fstab
          echo -e "${Green}The swap was created successfully and the following information was viewed:${Font}"
          cat /proc/swaps
          cat /proc/meminfo | grep Swap
  else
    echo -e "${Red}swapfile already exists, swap setting failed, please run the script to delete swap first and then set it again!${Font}"
  fi
}

del_swap(){
  grep -q "swapfile" /etc/fstab

  if [ $? -eq 0 ]; then
    echo -e "${Green}swapfile has been found and is in the process of removing it...${Font}"
    sed -i '/swapfile/d' /etc/fstab
    echo "3" > /proc/sys/vm/drop_caches
    swapoff -a
    rm -f /swapfile
      echo -e "${Green}swap is deleted！${Font}"
  else
      echo -e "${Red}swapfile not found，swap delete failed！${Font}"
  fi
}

main(){
root_need
ovz_no
del_swap
sleep 1
add_swap
}

main
