echo "running nfs install script";
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup_alma8_7;
sudo -E $SCHISM_SCRIPTS_HOME/batch/nfs_start.sh;
echo "linking to nfs /shared/data as simulations and changing directory to simulations";
ln -s /shared/data $AZ_BATCH_TASK_WORKING_DIR/simulations;
echo Coordination Task Done