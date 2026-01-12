#do this to cache the rpms for offline install
#yumdownloader --resolve --destdir ${LOCAL_INSTALL_DIR}/telegraf-rpms telegraf -y
# install telegraf from cached rpms
if [ -z "${AZ_BATCH_APP_PACKAGE_telegraf}" ]; then
    echo "AZ_BATCH_APP_PACKAGE_telegraf is not set. Exiting."
    exit 0; # Telegraf is optional
fi
echo "Installing telegraf from cached rpms in ${AZ_BATCH_APP_PACKAGE_telegraf}/telegraf-rpms"
yum localinstall --nogpgcheck ${AZ_BATCH_APP_PACKAGE_telegraf}/telegraf-rpms/*.rpm -y
