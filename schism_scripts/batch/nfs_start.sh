#!/bin/bash
# set -e
# arg: $1 = nfsserver
source $SCHISM_SCRIPTS_HOME/batch/azhpc-library.sh

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

# Count nodes in the job — AZ_BATCH_HOST_LIST is comma-separated
IFS=',' read -ra _host_array <<< "$AZ_BATCH_HOST_LIST"
num_hosts=${#_host_array[@]}
echo "Number of hosts in job: $num_hosts"

if [[ $AZ_BATCH_IS_CURRENT_NODE_MASTER == "true" ]]; then
    echo "This is the master node. $AZ_BATCH_NODE_ID, master node ip is $ip_address"
else
    echo "This is not the master node. $AZ_BATCH_NODE_ID"
fi

if [[ $AZ_BATCH_IS_CURRENT_NODE_MASTER == "true" ]]; then

    echo "Current node is master node"
    source $SCHISM_SCRIPTS_HOME/batch/nfs_common.sh

    # NVMe-aware disk setup: uses raw NVMe block devices directly (no fdisk partitioning)
    # following Azure HPC's configure_local_nvme_disks.sh approach.
    # Falls back to the existing setup_disks() for SCSI/managed disk VMs.
    setup_disks_auto() {
        # Re-run guard: if NFS_MOUNT_POINT is already a live mountpoint (e.g. this is a task
        # retry re-running coordination setup on a node already set up by a prior attempt),
        # skip disk setup entirely - re-formatting a mounted device corrupts it and breaks NFS.
        if mountpoint -q "$NFS_MOUNT_POINT" 2>/dev/null; then
            echo "$NFS_MOUNT_POINT is already mounted, skipping disk setup (idempotent re-run)"
            ln -sfn $NFS_SCRATCH /scratch
            return
        fi

        # Case 1: /mnt/resource is already mounted (Azure Batch pre-configured NVMe RAID,
        # as on HBv5 where all 8 NVMe disks are pre-assembled into md127 at /mnt/resource).
        # Just create the NFS directory structure on top of it — no disk setup needed.
        if mountpoint -q /mnt/resource 2>/dev/null; then
            echo "/mnt/resource is already mounted (pre-configured by Azure), using it directly for NFS"
            lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
            mkdir -p $NFS_MOUNT_POINT
            mkdir -p $NFS_APPS $NFS_DATA $NFS_HOME $NFS_SCRATCH
            chmod 777 $NFS_APPS $NFS_DATA $NFS_HOME $NFS_SCRATCH
            ln -sfn $NFS_SCRATCH /scratch
            add_export_once "$NFS_APPS    *(rw,no_root_squash)"
            add_export_once "$NFS_DATA    *(rw,no_root_squash)"
            add_export_once "$NFS_HOME    *(rw,no_root_squash)"
            add_export_once "$NFS_SCRATCH    *(rw,no_root_squash)"
            exportfs
            exportfs -a
            exportfs
            return
        fi

        # Case 2: Free NVMe devices present — format and RAID them directly (no fdisk),
        # following Azure HPC's configure_local_nvme_disks.sh approach.
        local free_nvme=()
        for dev in /dev/nvme*n[0-9]*; do
            [[ -b "$dev" ]] || continue
            if ! lsblk -no MOUNTPOINT "$dev" 2>/dev/null | grep -q '[^[:space:]]'; then
                free_nvme+=("$dev")
            fi
        done
        local nvme_count=${#free_nvme[@]}
        echo "Free NVMe devices found: $nvme_count  (${free_nvme[*]})"

        if [[ $nvme_count -eq 0 ]]; then
            echo "No free NVMe devices, using standard SCSI disk setup"
            setup_disks
            return
        fi

        mkdir -p $NFS_MOUNT_POINT

        # purge any stale fstab entry for this mountpoint left over from a prior job on a
        # reused pool node - otherwise `mount` (by mountpoint) can match a stale/old UUID
        # instead of the filesystem just formatted below, producing a "bad superblock" error.
        sed -i "\#[[:space:]]${NFS_MOUNT_POINT}[[:space:]]#d" /etc/fstab

        if [[ $nvme_count -eq 1 ]]; then
            echo "Single free NVMe device ${free_nvme[0]}, formatting directly as xfs"
            mkfs.xfs -f "${free_nvme[0]}"
            local uuid
            uuid=$(blkid -s UUID -o value "${free_nvme[0]}")
            echo "UUID=$uuid $NFS_MOUNT_POINT xfs rw,noatime,attr2,inode64,nobarrier,nofail 0 2" >> /etc/fstab
            mount -t xfs "${free_nvme[0]}" "$NFS_MOUNT_POINT"
        else
            echo "Multiple free NVMe devices (${free_nvme[*]}), creating RAID-0 /dev/md10"
            mdadm --create /dev/md10 --level 0 --raid-devices $nvme_count "${free_nvme[@]}"
            sleep 10
            mdadm --verbose --detail --scan > /etc/mdadm.conf
            mkfs.xfs -f /dev/md10
            local uuid
            uuid=$(blkid -s UUID -o value /dev/md10)
            echo "UUID=$uuid $NFS_MOUNT_POINT xfs rw,noatime,attr2,inode64,nobarrier,nofail 0 2" >> /etc/fstab
            mount -t xfs /dev/md10 "$NFS_MOUNT_POINT"
        fi

        mkdir -p $NFS_APPS $NFS_DATA $NFS_HOME $NFS_SCRATCH
        chmod 777 $NFS_APPS $NFS_DATA $NFS_HOME $NFS_SCRATCH
        ln -sfn $NFS_SCRATCH /scratch

        add_export_once "$NFS_APPS    *(rw,no_root_squash)"
        add_export_once "$NFS_DATA    *(rw,no_root_squash)"
        add_export_once "$NFS_HOME    *(rw,no_root_squash)"
        add_export_once "$NFS_SCRATCH    *(rw,no_root_squash)"

        exportfs
        exportfs -a
        exportfs
    }

    if [[ $num_hosts -gt 1 ]]; then
        echo "Multi-node job ($num_hosts hosts): starting NFS server"
        systemctl enable rpcbind
        systemctl enable nfs-server
        if is_centos7; then
            systemctl enable nfs-lock
            systemctl enable nfs-idmap
            systemctl enable nfs
        fi

        systemctl start rpcbind
        systemctl start nfs-server
        if is_centos7; then
            systemctl start nfs-lock
            systemctl start nfs-idmap
            systemctl start nfs
        fi

        setup_disks_auto
        tune_nfs
        systemctl restart nfs-server
    else
        echo "Single-node job: skipping NFS server, creating shared dirs directly"
        setup_disks_auto
    fi

    ln -s /shared/apps /apps
    ln -s /shared/data /data

    df

    echo "Started NFS server on $nfs_server, i.e. $ip_address"
fi

mkdir -p /shared/scratch || echo "scratch already exists"
mkdir -p /shared/apps || echo "apps already exists"
mkdir -p /shared/data || echo "data already exists"
mkdir -p /shared/home || echo "home already exists"

chmod 777 /shared/scratch

if [[ $num_hosts -gt 1 ]]; then
    # NFS mount options
    #nfs_mount_options="rw,sync,rsize=131072,wsize=131072,noacl,nocto,noatime,nodiratime"
    nfs_mount_options="rw,rsize=65536,wsize=65536,noatime,nodiratime"

    cat << EOF >> /etc/fstab
$nfs_server:$nfs_share/home           /shared/home   nfs $nfs_mount_options 0 0
$nfs_server:/mnt/resource/scratch /shared/scratch      nfs $nfs_mount_options 0 0
$nfs_server:$nfs_share/apps    /shared/apps   nfs $nfs_mount_options 0 0
$nfs_server:$nfs_share/data    /shared/data   nfs $nfs_mount_options 0 0
EOF

    setsebool -P use_nfs_home_dirs 1

    TIMEOUT=120
    elapsed=0
    while [ $elapsed -lt $TIMEOUT ]; do
        # Mount only NFS entries to avoid spurious failures from local device
        # fstab entries (e.g. /dev/nvme0n1) present in Alma 8.10 HPC images
        # that are not formatted on non-master nodes.
        mount -a -t nfs,nfs4
        if [ $? -eq 0 ]; then
            break
        fi
        echo "Waiting for NFS server to be ready..."
        sleep 5
        elapsed=$((elapsed+5))
    done
else
    # Single-node: bind-mount NFS dirs directly to /shared/* so paths are identical
    echo "Single-node: bind-mounting NFS dirs to /shared/*"
    mount --bind $nfs_share/home    /shared/home
    mount --bind /mnt/resource/scratch /shared/scratch
    mount --bind $nfs_share/apps    /shared/apps
    mount --bind $nfs_share/data    /shared/data
fi

df

echo "NFS client configuration complete."


