#!/bin/env bash
tee > /tmp/oneAPI.repo << EOF
[oneAPI]
name=Intel® oneAPI repository
baseurl=https://yum.repos.intel.com/oneapi
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
EOF
# install intel oneAPI
mv /tmp/oneAPI.repo /etc/yum.repos.d
# check to see if atleast one argument is passed
INTEL_VERSION=""
if [[ $# -eq 0 ]] ; then
    echo "No version specified, installing latest (blank)"
    INTEL_VERSION="latest"
    tee > /tmp/intel-config.txt << EOF
dev-utilities=$INTEL_VERSION
compiler=$INTEL_VERSION
mpi=$INTEL_VERSION
EOF
    INTEL_VERSION=""
else
    INTEL_VERSION="2021.4.0" # FIXME: the version naming by Intel is all over the place :(
    echo "Installing version $1"
    tee > /tmp/intel-config.txt << EOF
dev-utilities=$INTEL_VERSION
compiler=$INTEL_VERSION
mpi=$INTEL_VERSION
EOF
    INTEL_VERSION="-$1" # argument of the form 2021.4.0.x86_64
fi

[[ ! -v USE_CACHED_INSTALL ]] && yumdownloader --resolve --destdir ${LOCAL_INSTALL_DIR}/intel-rpms intel-basekit-runtime"$INTEL_VERSION" intel-oneapi-compiler-fortran-runtime"$INTEL_VERSION" intel-oneapi-mpi"$INTEL_VERSION" -y
yum localinstall --nogpgcheck ${LOCAL_INSTALL_DIR}/intel-rpms/*.rpm -y
