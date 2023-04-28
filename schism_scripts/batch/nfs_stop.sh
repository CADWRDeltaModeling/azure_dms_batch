if [[ $AZ_BATCH_IS_CURRENT_NODE_MASTER == "true" ]]; then
    echo "This is the master node. $AZ_BATCH_NODE_ID"
    # only on master node
    systemctl stop nfs-server
    umount /mnt/resource/nfs
    rm -rf /mnt/resource/nfs
    rm -rf /mnt/resource/scratch
else
    echo "This is not the master node. $AZ_BATCH_NODE_ID"
fi
# on all nodes
mv /etc/fstab.bak /etc/fstab
umount /shared/scratch
umount /shared/home
umount /shared/apps
umount /shared/data
rm -rf /shared/
rm -rf /apps
rm -rf /data
#