## Enable sudo for _azbatch
echo "_azbatch ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/azbatch
echo "Defaults:_azbatch !requiretty" >> /etc/sudoers.d/azbatch
# Disable requiretty to allow run sudo within scripts
sed -i -e 's/Defaults    requiretty.*/ #Defaults    requiretty/g' /etc/sudoers