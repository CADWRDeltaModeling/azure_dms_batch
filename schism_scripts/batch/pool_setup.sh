#!/bin/bash
# schism release identifier. E.g. schism_release="schismv5.10.1". Used with name of the url from github release
# schism_file="schism_5_10_1_alma_8_5_HPC_gen1"
# E.g. 
# https://github.com/CADWRDeltaModeling/azure_dms_batch/releases/download/${schism_release}/${schism_file}.tar.gz
schism_release=$1
schism_file=$2
echo "Downloading and installing from https://github.com/CADWRDeltaModeling/azure_dms_batch/archive/refs/tags/${schism_release}.tar.gz"
pushd /tmp
wget "https://github.com/CADWRDeltaModeling/azure_dms_batch/archive/refs/tags/${schism_release}.tar.gz"
tar xvzf ${schism_release}.tar.gz
pushd azure_dms_batch-${schism_release}/schism_scripts/batch
echo "Starting pool install script..."
(source ./install-azcopy.sh)
echo "Starting Intel oneAPI installation..."
(source ./setup_intel_schism.sh)
echo "Starting NFS installation..."
(source ./nfs_install.sh)
echo "Done with NFS install"
echo "Starting insights installation..."
(source ./appinsights_install.sh)
echo "Done enabling insights"
echo "Done with pool installs"
#
(source ./enable_sudo_for_batch.sh)
echo "Starting SCHISM installation..."
(source ./schism_install.sh; install_schism $schism_release $schism_file)
echo "Done with SCHISM install"
popd
rm -rf azure_dms_batch-${schism_release} ${schism_release}.tar.gz
popd
