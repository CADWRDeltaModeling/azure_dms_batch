#!/bin/bash
if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi


source $AZ_BATCH_NODE_MOUNTS_DIR/batch/azhpc-library.sh

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

## FIXME: move this to another script 
## Enable RDMA communication for root user
cp -rv /home/_azbatch/.ssh /root/.
sed -i 's/home\/_azbatch/root/g' /root/.ssh/config
chmod 700 /root/.ssh
chmod 644 /root/.ssh/config
chmod 644 /root/.ssh/authorized_keys

## Enable sudo for _azbatch
echo "_azbatch ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/azbatch
echo "Defaults:_azbatch !requiretty" >> /etc/sudoers.d/azbatch
