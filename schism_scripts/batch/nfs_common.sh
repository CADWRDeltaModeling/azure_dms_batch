
# Shares
NFS_MOUNT_POINT=/mnt/resource/nfs
NFS_APPS=$NFS_MOUNT_POINT/apps
NFS_DATA=$NFS_MOUNT_POINT/data
NFS_HOME=$NFS_MOUNT_POINT/home
NFS_SCRATCH=/mnt/resource/scratch


read_os()
{
    os_release=$(cat /etc/os-release | grep "^ID\=" | cut -d'=' -f 2 | sed -e 's/^"//' -e 's/"$//')
    os_maj_ver=$(cat /etc/os-release | grep "^VERSION_ID\=" | cut -d'=' -f 2 | sed -e 's/^"//' -e 's/"$//')
    full_version=$(cat /etc/$os_release-release | cut -d' ' -f4)
}


# Partitions all data disks attached to the VM
#
setup_data_disks()
{
    mountPoint="$1"
    filesystem="$2"
    devices="$3"
    raidDevice="$4"
    createdPartitions=""
    numdevices=`echo $devices | wc -w`
    if [ $numdevices -gt 1 ]
    then
    # Loop through and partition disks until not found
       for disk in $devices; do
           fdisk -l /dev/$disk || break
           fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
           createdPartitions="$createdPartitions /dev/${disk}p1"
       done
    else
        disk=$(echo $devices | tr -d [:space:])
        echo "Warning: Only a single device to partition, $disk"
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


w
EOF
        createdPartitions="$createdPartitions /dev/${disk}p1"
    fi

    sleep 10

    # Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        if [ $numdevices -gt 1 ]
        then
           mdadm --create /dev/$raidDevice --level 0 --raid-devices $devices $createdPartitions
           sleep 10

           mdadm /dev/$raidDevice
        else
           echo "Warning: mdadm is not called, we have one partition named, ${disk}1 for mountpoint, $mountPoint"
           raidDevice=${disk}1
        fi

        if [ "$filesystem" == "xfs" ]; then
            mkfs -t $filesystem /dev/$raidDevice
            export xfsuuid="UUID=`blkid |grep dev/$raidDevice |cut -d " " -f 2 |cut -c 7-42`"
#            echo "$xfsuuid $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,sunit=1024,swidth=4096,nofail 0 2" >> /etc/fstab
            echo "$xfsuuid $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,nofail 0 2" >> /etc/fstab
        else
            mkfs.ext4 -i 2048 -I 512 -J size=400 -Odir_index,filetype /dev/$raidDevice
            sleep 5
            tune2fs -o user_xattr /dev/$raidDevice
            export ext4uuid="UUID=`blkid |grep dev/$raidDevice |cut -d " " -f 2 |cut -c 7-42`"
            echo "$ext4uuid $mountPoint $filesystem noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
        fi

        sleep 10
        mount /dev/$raidDevice $mountPoint # mount -a is not working ?
    fi
}

setup_single_disk()
{
    mountPoint="$1"
    filesystem="$2"
    device="$3"

    fdisk -l /dev/$device || break
    fdisk /dev/$device << EOF
n
p
1


p
w
EOF

    if [ "$filesystem" == "xfs" ]; then
        mkfs -t $filesystem /dev/$device
        echo "/dev/$device $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,nofail 0 2" >> /etc/fstab
    else
        mkfs.ext4 -F -i 2048 -I 512 -J size=400 -Odir_index,filetype /dev/$device
        sleep 5
        tune2fs -o user_xattr /dev/$device
        echo "/dev/$device $mountPoint $filesystem noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
    fi

    sleep 10

    mount /dev/$device $mountPoint
}

setup_disks()
{
    # Dump the current disk config for debugging
    fdisk -l

    # Dump the scsi config
    lsscsi

    # Get the root/OS disk so we know which device it uses and can ignore it later
    rootDevice=$(mount | grep "on / type" | awk '{print $1}' | sed 's/[0-9]//g')

    # Get the TMP disk so we know which device and can ignore it later
    if is_centos7; then
        tmpDevice=$(mount | grep "on /mnt/resource type" | awk '{print $1}' | sed 's/[0-9]//g')
    else
        tmpDevice=$(mount | grep "on /mnt type" | awk '{print $1}' | sed 's/[0-9]//g')
    fi

    # Get the data disk sizes from fdisk, we ignore the disks above
    dataDiskSize=$(fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | awk '{print $3}' | sort -n -r | tail -1)

    # Compute number of disks
    nbDisks=$(fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | wc -l)
    echo "nbDisks=$nbDisks"

    dataDevices="$(fdisk -l | grep '^Disk /dev/' | grep $dataDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | head -$nbDisks | tr '\n' ' ' | sed 's|/dev/||g')"

    mkdir -p $NFS_MOUNT_POINT


    if [ "$nbDisks" -eq "1" ]; then
        setup_single_disk $NFS_MOUNT_POINT "ext4" "$dataDevices"
    elif [ "$nbDisks" -gt "1" ]; then
        setup_data_disks $NFS_MOUNT_POINT "xfs" "$dataDevices" "md10"
    fi

    mkdir -p $NFS_APPS
    mkdir -p $NFS_DATA
    mkdir -p $NFS_HOME
    mkdir -p $NFS_SCRATCH
    chmod 777 $NFS_APPS
    chmod 777 $NFS_DATA
    chmod 777 $NFS_HOME
    chmod 777 $NFS_SCRATCH

    ln -s $NFS_SCRATCH /scratch

    echo "$NFS_APPS    *(rw,no_root_squash)" >> /etc/exports
    echo "$NFS_DATA    *(rw,no_root_squash)" >> /etc/exports
    echo "$NFS_HOME    *(rw,no_root_squash)" >> /etc/exports
    echo "$NFS_SCRATCH    *(rw,no_root_squash)" >> /etc/exports

    exportfs
    exportfs -a
    exportfs
}

tune_nfs()
{
    cores=$(grep processor /proc/cpuinfo | wc -l)
    nfs_proc=$(($cores * 1))
    # fix for alma8, change in nfs config file location to /etc/nfs.conf
    # https://access.redhat.com/solutions/2216
    if [[ -f /etc/sysconfig/nfs ]]; then
        echo "using /etc/sysconfig/nfs"
        replace="s/#RPCNFSDCOUNT=16/RPCNFSDCOUNT=$nfs_proc/g"
        sed -i -e "$replace" /etc/sysconfig/nfs
        grep RPCNFSDCOUNT /etc/sysconfig/nfs
    else
        echo "using /etc/nfs.conf"
        replace="s/# threads=8/threads=$nfs_proc/g"
        sed -i -e "$replace" /etc/nfs.conf
        grep threads /etc/nfs.conf
    fi
}

# nfs server will be started when tasks are assigned as till then there is no $AZ_BATCH_NODE_LIST or $AZ_BATCH_MASTER_NODE
# see nfs_start.sh