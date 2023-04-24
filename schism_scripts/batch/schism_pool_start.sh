#!/bin/bash
echo "Starting Intel oneAPI installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/setup_intel_schism.sh
echo "Starting BeeOND installation..."
source $AZ_BATCH_NODE_MOUNTS_DIR/batch/beeond_install.sh
echo "Done pool start script."