#!/bin/bash
# schism release identifier. E.g. schism_release="schismv5.10.1". Used with name of the url from github release
# schism_file="schism_5_10_1_alma_8_5_HPC_gen1"
# E.g. 
# https://github.com/CADWRDeltaModeling/azure_dms_batch/releases/download/${schism_release}/${schism_file}.tar.gz

# Default values for flags
uselatest=true

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

# Access and use the arguments
schism_release="$1"
schism_file="$2"
echo "Downloading and installing from https://github.com/CADWRDeltaModeling/azure_dms_batch/archive/refs/tags/${schism_release}.tar.gz"
pushd /tmp || exit
mkdir -p /opt
if [ "$uselatest" = true ]; then
  echo "Using latest scripts from github"
    # temporary way to get latest code into the pool
    wget https://github.com/CADWRDeltaModeling/azure_dms_batch/archive/refs/heads/main.zip
    unzip main.zip
    mv azure_dms_batch-main/schism_scripts /opt
else
  echo "Using scripts from release ${schism_release}"
    wget "https://github.com/CADWRDeltaModeling/azure_dms_batch/archive/refs/tags/${schism_release}.tar.gz"
    tar xvzf "${schism_release}.tar.gz"
    mv "azure_dms_batch-${schism_release}/schism_scripts" /opt
fi
#
pushd /opt/schism_scripts/batch || exit
chmod +x *.sh
(source ./enable_sudo_for_batch.sh)
echo "Starting pool install script..."
(source ./install-azcopy.sh)
echo "Starting Intel oneAPI installation..."
(source ./setup_intel_schism.sh)
echo "Starting NFS installation..."
(source ./nfs_install.sh)
echo "Done with NFS install"
echo "Starting insights installation..."
(source ./appinsights_install.sh "v1.3.0")
echo "Done enabling insights"
echo "Done with pool installs"
#
echo "Starting SCHISM installation..."
(source ./schism_install.sh; install_schism "$schism_release" "$schism_file")
echo "Done with SCHISM install"
popd
popd
echo "Done with pool setup script"
