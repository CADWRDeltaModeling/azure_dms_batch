#!/bin/bash
echo "Starting Intel oneAPI installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/setup_intel_schism.sh
echo "Starting NFS installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/nfs_install.sh
echo "Done pool start script."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/enable_app_insights.sh
echo "Done enabling insights"