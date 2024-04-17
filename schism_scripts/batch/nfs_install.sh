#!/bin/bash
if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/azhpc-library.sh

read_os


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

#[[ ! -v USE_CACHED_INSTALL ]] && yumdownloader --resolve --destdir ${LOCAL_INSTALL_DIR}/nfs-rpms epel-release ${yum_list} -y
yum localinstall --nogpgcheck ${AZ_BATCH_APP_PACKAGE_nfs_alma8_7}/*.rpm -y

