## Enable RDMA communication for root user
echo "Enabling root ssh passwordless"
[[ $(type -t cp) == "alias" ]] && unalias cp
cp -rv /home/_azbatch/.ssh /root/.
sed -i 's/home\/_azbatch/root/g' /root/.ssh/config
chmod 700 /root/.ssh
chmod 644 /root/.ssh/config
chmod 644 /root/.ssh/authorized_keys
sed -i 's/PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl reload sshd
echo "Done enabling root ssh passwordless"