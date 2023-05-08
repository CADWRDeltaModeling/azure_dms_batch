echo "running enable_app_insights.sh";
sudo -E $AZ_BATCH_NODE_MOUNTS_DIR/batch/enable_app_insights.sh;
echo "running nfs install script";
sudo -E $AZ_BATCH_NODE_MOUNTS_DIR/batch/nfs_start.sh;
echo "linking to nfs /shared/data as simulations and changing directory to simulations";
ln -s /shared/data $AZ_BATCH_TASK_WORKING_DIR/simulations;
echo Coordination Task Done