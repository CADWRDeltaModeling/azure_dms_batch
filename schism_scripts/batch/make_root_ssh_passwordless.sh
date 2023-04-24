mkdir -p /root/.ssh
chmod 700 /root/.ssh
pushd /root/.ssh
cp ~_azbatch/.ssh/authorized_keys .
cp ~_azbatch/.ssh/intra_pool_rsa id_rsa
chmod 600 authorized_keys id_rsa
sed -i 's/PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl reload sshd
