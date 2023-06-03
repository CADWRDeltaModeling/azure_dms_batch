#!/bin/bash
if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/azhpc-library.sh

read_os
# Disable requiretty to allow run sudo within scripts
sed -i -e 's/Defaults    requiretty.*/ #Defaults    requiretty/g' /etc/sudoers

yum -y install epel-release

case "$os_maj_ver" in
    7)
        yum_list="nfs-utils nfs-utils-lib"
    ;;
    8)
        yum_list="nfs-utils"
    ;;
    8.6)
        yum_list="nfs-utils"
    ;;
esac
yum -y install $yum_list
