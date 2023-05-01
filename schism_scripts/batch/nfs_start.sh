#!/bin/bash
# set -e
# arg: $1 = nfsserver
master_node=$AZ_BATCH_MASTER_NODE
ip_address=$(echo $master_node | cut -d: -f1)
echo "Master node IP address: $ip_address"

nfs_server=${1-$ip_address}
nfs_share=${2-/mnt/resource/nfs} # NFS_MOUNT_POINT from nfs_common.sh 
if [ -z "$nfs_server" ]; then
    echo "The nfs_server is required"
    exit 1
fi

cp /etc/fstab /etc/fstab.bak # to restore later in task deletion stage

if [[ $AZ_BATCH_IS_CURRENT_NODE_MASTER == "true" ]]; then
    echo "This is the master node. $AZ_BATCH_NODE_ID, master node ip is $ip_address"
else
    echo "This is not the master node. $AZ_BATCH_NODE_ID"
fi

if [[ $AZ_BATCH_IS_CURRENT_NODE_MASTER == "true" ]]; then

    echo "Current nodes is master node so starting NFS server"
    source $AZ_BATCH_NODE_MOUNTS_DIR/batch/nfs_common.sh
    systemctl enable rpcbind
    systemctl enable nfs-server
    systemctl enable nfs-lock
    systemctl enable nfs-idmap
    systemctl enable nfs

    systemctl start rpcbind
    systemctl start nfs-server
    systemctl start nfs-lock
    systemctl start nfs-idmap
    systemctl start nfs

    setup_disks
    tune_nfs
    systemctl restart nfs-server

    ln -s /shared/apps /apps
    ln -s /shared/data /data

    df

    echo "Started NFS server on $nfs_server, i.e. $ip_address"
fi

yum install -y nfs-utils

mkdir -p /shared/scratch || echo "scratch already exists"
mkdir -p /shared/apps || echo "apps already exists"
mkdir -p /shared/data || echo "data already exists"
mkdir -p /shared/home || echo "home already exists"

chmod 777 /shared/scratch

# NFS mount options
nfs_mount_options="rw,sync,rsize=65536,wsize=65536"

cat << EOF >> /etc/fstab
$nfs_server:$nfs_share/home           /shared/home   nfs $nfs_mount_options 0 0
$nfs_server:/mnt/resource/scratch /shared/scratch      nfs $nfs_mount_options 0 0
$nfs_server:$nfs_share/apps    /shared/apps   nfs $nfs_mount_options 0 0
$nfs_server:$nfs_share/data    /shared/data   nfs $nfs_mount_options 0 0
EOF

setsebool -P use_nfs_home_dirs 1

TIMEOUT=60
elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    mount -a
    if [ $? -eq 0 ]; then
        break
    fi
    echo "Waiting for NFS server to be ready..."
    sleep 5
    elapsed=$((elapsed+5))
done

df

echo "NFS client configuration complete."


