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
yum install intel-oneapi-mpi -y
yum install intel-basekit-runtime -y
yum install intel-oneapi-compiler-fortran-runtime -y
# install schism
cd /opt
cp $AZ_BATCH_NODE_MOUNTS_DIR/batch/schism_all.tar.gz .
tar xvzf schism_all.tar.gz
