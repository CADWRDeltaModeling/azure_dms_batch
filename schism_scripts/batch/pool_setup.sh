#!/bin/bash
# Pool setup scripts are from the application package
# set SCRIPT_HOME to the location of this running script
export SCRIPT_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
# Parse named arguments using getopts
while getopts ":r" opt; do
  case $opt in
    r)
      uselatest=false # use release if -r is passed
      ;;
    *)
      echo "Unknown parameter passed: $OPTARG"
      exit 1
      ;;
  esac
done

# Shift the named arguments
shift $((OPTIND - 1))

#
pushd ${SCRIPT_HOME} || exit
chmod +x *.sh
# Now in ${SCRIPT_HOME} for the rest of the script
./enable_sudo_for_batch.sh
echo "Starting pool install script..."
./install-azcopy.sh
echo "Starting NFS installation..."
./nfs_install.sh
echo "Done with NFS install"
echo "Starting insights installation..."
./appinsights_install.sh "v1.3.0"
./appinsights_start.sh
echo "Done enabling insights"
echo "Done with pool installs"
popd
popd
echo "Done with pool setup script"
