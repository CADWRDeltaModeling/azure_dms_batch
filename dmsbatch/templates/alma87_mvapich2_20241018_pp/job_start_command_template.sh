echo "Job Start Task Start for PP"
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup
[[ -z "$AZ_BATCH_APP_PACKAGE_schimpy_with_deps" ]] && echo "schimpy_with_deps package not found" || (echo "schimpy_with_deps package found" && pushd $AZ_BATCH_APP_PACKAGE_schimpy_with_deps && tar -xzf schimpy.tar.gz && rm -f schimpy.tar.gz && popd)
[[ -z "$AZ_BATCH_APP_PACKAGE_suxarray_with_deps" ]] && echo "suxarray_with_deps package not found" || (echo "suxarray_with_deps package found" && cd $AZ_BATCH_APP_PACKAGE_suxarray_with_deps && tar -xzf suxarray.tar.gz --overwrite && rm -f suxarray.tar.gz && echo "tar unpacked suxarray" && source bin/activate && conda-unpack)
echo "Job Start Task Done for PP"
# source the schimpy with deps and pip install bdschism
# if $AZ_BATCH_APP_PACKAGE_schimpy_with_deps and $AZ_BATCH_APP_PACKAGE_baydeltaschism are both present, then we can source schimpy_with_deps and install bdschism which depends on schimpy, otherwise skip and rely on user to have set up environment and installed bdschism in their own way (e.g. via a custom application command)
if [[ -z $AZ_BATCH_APP_PACKAGE_schimpy_with_deps ]]; then
    echo "schimpy_with_deps package not found"
else 
    source $AZ_BATCH_APP_PACKAGE_schimpy_with_deps/bin/activate;
    SETUPTOOLS_SCM_PRETEND_VERSION=1.0.0 pip install -e $AZ_BATCH_APP_PACKAGE_baydeltaschism/bdschism --no-deps;
fi
