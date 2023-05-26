# install schism

function install_schism {
    version=$1
    # assumes that schism...tar.gz contains an opt directory
    pushd /
    cp $AZ_BATCH_NODE_MOUNTS_DIR/batch/apps/schism_${version}.tar.gz .
    tar xvzf schism_${version}.tar.gz
    rm schism_${version}.tar.gz
    popd
    echo "Installed schism_${version}.tar.gz"
}


