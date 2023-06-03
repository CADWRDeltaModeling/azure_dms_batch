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
