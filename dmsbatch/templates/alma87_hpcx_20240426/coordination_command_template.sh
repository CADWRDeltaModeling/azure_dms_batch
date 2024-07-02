echo "running nfs install script";
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup_alma8_7;
pushd $AZ_BATCH_APP_PACKAGE_schimpy_with_deps_rhel8_7; 
tar -xzf schism.tar.gz && rm -f schism.tar.gz;
popd;
sudo -E $SCHISM_SCRIPTS_HOME/batch/nfs_start.sh;
echo "linking to nfs /shared/data as simulations and changing directory to simulations";
ln -s /shared/data $AZ_BATCH_TASK_WORKING_DIR/simulations;
# if telegraf is available, run it
if [ -n "$AZ_BATCH_APP_PACKAGE_telegraf" ]; then
  echo "running telegraf install script";
  pushd $AZ_BATCH_APP_PACKAGE_telegraf;
  sudo bash ./install_telegraf.sh;
  popd;
fi;
echo Coordination Task Done