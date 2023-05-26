#!/bin/bash
#E.g. schism_version="all_v5.10.1". Used with name of tar.gz file as schism_${schism_version}.tar.gz
schism_version=$1
echo "Starting Intel oneAPI installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/setup_intel_schism.sh
echo "Starting NFS installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/nfs_install.sh
echo "Starting insights installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/appinsights_install.sh
echo "Done pool start script."
#
echo "Starting SCHISM installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/schism_install.sh
install_schism $schism_version

