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

if [[ -z "$1" ]]; then
    echo "No version specified, installing latest (blank)"
    VERSION=""
else
    echo "Installing version $1"
    VERSION="-$1" # argument of the form 2021.4.0.x86_64
fi

yum install intel-basekit-runtime"$VERSION" -y
yum install intel-oneapi-compiler-fortran-runtime"$VERSION" -y
yum install intel-oneapi-mpi"$VERSION" -y