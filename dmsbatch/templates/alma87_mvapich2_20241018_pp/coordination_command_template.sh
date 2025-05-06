echo "running nfs install script";
tar -xzf schimpy.tar.gz && rm -f schimpy.tar.gz;
pushd $AZ_BATCH_APP_PACKAGE_suxarray_with_deps; 
tar -xzf suxarray.tar.gz && rm -f suxarray.tar.gz;
popd;
echo Coordination Task Done