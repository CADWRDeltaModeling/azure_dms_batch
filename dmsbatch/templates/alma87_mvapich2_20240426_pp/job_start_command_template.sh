echo "Job Start Task Start"
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup_alma8_7
pushd $AZ_BATCH_APP_PACKAGE_schimpy_with_deps_rhel8_7
tar -xzf schism.tar.gz && rm -f schism.tar.gz
popd
echo "Job Start Task Done"