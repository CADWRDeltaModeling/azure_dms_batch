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
git clone https://github.com/Azure/azurehpc.git /opt/azurehpc
sudo yum install -y mdadm
# create raid0 with all nvme disks
/opt/azurehpc/scripts/create_raid0.sh /dev/md10 /dev/nvme*n1
mkfs.xfs /dev/md10
mount /dev/md10 /mnt/local
#parted /dev/nvme0n1 --script mklabel gpt mkpart xfspart xfs 0% 100% 
#mkfs.xfs /dev/nvme0n1p1 
#mount /dev/nvme0n1p1 /mnt/local 
chmod 1777 /mnt/local
#
app_insights_version="v1.3.0"
export BATCH_INSIGHTS_DOWNLOAD_URL="https://github.com/Azure/batch-insights/releases/download/${app_insights_version}/batch-insights"
wget  -O - https://raw.githubusercontent.com/Azure/batch-insights/master/scripts/run-linux.sh | bash
#
./batch-insights $AZ_BATCH_INSIGHTS_ARGS  > /tmp/batch-insights.log &
