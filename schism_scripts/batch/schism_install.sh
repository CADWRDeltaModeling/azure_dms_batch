#!/bin/env bash
# install schism

function install_schism {
    schism_release=$1
    schism_file=$2
    # assumes that schism...tar.gz contains an opt directory
    pushd /
    [[ ! -v USE_CACHED_INSTALL ]] && wget https://github.com/CADWRDeltaModeling/azure_dms_batch/releases/download/${schism_release}/${schism_file}.tar.gz -O ${LOCAL_INSTALL_DIR}/${schism_file}.tar.gz
    (cp ${LOCAL_INSTALL_DIR}/${schism_file}.tar.gz .; tar xvzf ${schism_file}.tar.gz; rm -f ${schism_file}.tar.gz)
    popd
    echo "Installed ${schism_file}.tar.gz"
}

