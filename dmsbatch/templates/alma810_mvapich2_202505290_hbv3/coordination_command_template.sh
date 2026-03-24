echo "running nfs install script";
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup;
pushd $AZ_BATCH_APP_PACKAGE_schimpy_with_deps; 
tar -xzf schimpy.tar.gz && rm -f schimpy.tar.gz;
popd;
pushd $AZ_BATCH_APP_PACKAGE_suxarray_with_deps; 
tar -xzf suxarray.tar.gz && rm -f suxarray.tar.gz;
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