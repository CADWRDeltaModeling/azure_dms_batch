#!/bin/bash
# E.g. "5_10_1_alma_8_5_HPC_gen1". Used to find schism_${schism_version}.tar.gz
schism_version=$1
echo "Starting pool install script..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/install-azcopy.sh
echo "Starting Intel oneAPI installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/setup_intel_schism.sh
echo "Starting NFS installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/nfs_install.sh
echo "Done with NFS install"
echo "Starting insights installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/appinsights_install.sh
echo "Done enabling insights"
echo "Done with pool installs"
#
echo "Starting SCHISM installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/schism_install.sh
install_schism $schism_version
echo "Done with SCHISM install"
