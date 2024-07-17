echo "Job Start Task Start"
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup
pushd $AZ_BATCH_APP_PACKAGE_schimpy_with_deps
tar -xzf schimpy.tar.gz && rm -f schimpy.tar.gz
popd
echo "Job Start Task Done"