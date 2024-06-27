#!/bin/bash
# Pool setup scripts are from the application package
# set SCRIPT_HOME to the location of this running script
export SCRIPT_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
echo "Changing to directory: $SCRIPT_HOME"
#
pushd ${SCRIPT_HOME} || exit
chmod +x *.sh
# Now in ${SCRIPT_HOME} for the rest of the script
./enable_sudo_for_batch.sh
echo "Starting pool install script..."
./install-azcopy.sh
echo "Installing telegraf..."
./install-telegraf.sh
echo "Done with telegraf install"
echo "Setting up shared disk"
source ./nfs_common.sh
setup_disks
ln -s /shared/apps /apps
ln -s /shared/data /data

df
echo "Done with shared disk setup"
echo "Done with pool installs"
popd
echo "Done with pool setup script"
