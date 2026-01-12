#do this to cache the rpms for offline install
#yumdownloader --resolve --destdir ${LOCAL_INSTALL_DIR}/telegraf-rpms telegraf -y
# install telegraf from cached rpms
yum localinstall --nogpgcheck ./telegraf-rpms/*.rpm -y
