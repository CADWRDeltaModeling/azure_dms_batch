#!/bin/bash

pushd /usr/local/bin
[[ ! -v USE_CACHED_INSTALL ]] && wget -q https://aka.ms/downloadazcopy-v10-linux -O ${LOCAL_INSTALL_DIR}/azcopy.tar
tar zxf ${LOCAL_INSTALL_DIR}/azcopy.tar --strip-components 1 --wildcards '*/azcopy'
chmod 755 /usr/local/bin/azcopy 
popd
