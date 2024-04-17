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

yum localinstall --nogpgcheck ${AZ_BATCH_APP_PACKAGE_intel_oneapi_fortran_runtime_2023_1_0}/*.rpm -y
