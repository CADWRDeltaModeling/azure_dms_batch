#!/bin/bash
#
sudo yum install -y git wget
#
function install_azcopy { 
    pushd /usr/bin 
    wget -q https://aka.ms/downloadazcopy-v10-linux -O - | sudo tar zxf - --strip-components 1 --wildcards '*/azcopy' 
    sudo chmod 755 /usr/bin/azcopy  
    azcopy --version 
    popd 
} 
install_azcopy
# mount the local disk
mkdir /mnt/local 
parted /dev/nvme0n1 --script mklabel gpt mkpart xfspart xfs 0% 100% 
mkfs.xfs /dev/nvme0n1p1 
mount /dev/nvme0n1p1 /mnt/local 
chmod 1777 /mnt/local
