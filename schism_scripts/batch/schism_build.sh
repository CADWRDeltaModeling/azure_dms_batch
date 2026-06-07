#!/bin/bash
# assumes root user is running this script. 
# Build all from a clean (Almalinx) Linux machine
set -e
# Initialize module system (needed when running under sudo)
if [ -f /etc/profile.d/modules.sh ]; then
  source /etc/profile.d/modules.sh
fi
#
# ============================================================
# Configuration - defaults used when env vars are not set.
# Override any of these by passing them via the environment
# (e.g. sudo env SCHISM_VERSION=v5.14.0 bash schism_build.sh hpcx)
# or by setting them in the build_schism.yml job config.
# ============================================================
# SCHISM and OS identifiers (used in the output package name)
export SCHISM_VERSION="${SCHISM_VERSION:-v5.13}"
export OSVER="${OSVER:-alma8.10hpc}"

# MPI variant-specific settings
MVAPICH2_VERSION="${MVAPICH2_VERSION:-2.3.7-1-ndr-patch}"
URL_HPCKIT="${URL_HPCKIT:-https://registrationcenter-download.intel.com/akdlm/IRC_NAS/7f096850-dc7b-4c35-90b5-36c12abd9eaa/l_HPCKit_p_2024.1.0.560.sh}"

# Install prefixes
PREFIX_HDF5="${PREFIX_HDF5:-/opt/hdf5}"
PREFIX_NETCDF="${PREFIX_NETCDF:-/opt/netcdf-c}"
PREFIX_NETCDF_FORTRAN="${PREFIX_NETCDF_FORTRAN:-/opt/netcdf-fortran}"

# Dependency versions — override to pick up a newer release
HDF5_VERSION="${HDF5_VERSION:-1.14.3}"
NETCDF_C_VERSION="${NETCDF_C_VERSION:-4.10.0}"
NETCDF_FORTRAN_VERSION="${NETCDF_FORTRAN_VERSION:-4.6.2}"
GOTM_VERSION="${GOTM_VERSION:-v6.0.7}"

# URLs derived from version numbers (override directly if the URL pattern changes)
# HDF5: GitHub release URL is unreliable; use the HDF Group S3 bucket instead.
# The S3 path uses underscores (HDF5_1_14_3) while the filename uses dots (hdf5-1.14.3).
HDF5_VERSION_PATH="${HDF5_VERSION//./_}"
URL_HDF5="${URL_HDF5:-https://hdf-wordpress-1.s3.amazonaws.com/wp-content/uploads/manual/HDF5/HDF5_${HDF5_VERSION_PATH}/src/hdf5-${HDF5_VERSION}.tar.gz}"
URL_NETCDF="${URL_NETCDF:-https://github.com/Unidata/netcdf-c/archive/refs/tags/v${NETCDF_C_VERSION}.tar.gz}"
URL_NETCDF_FORTRAN="${URL_NETCDF_FORTRAN:-https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v${NETCDF_FORTRAN_VERSION}.tar.gz}"

# CMake flags applied to all pschism builds
CMAKE_BASE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBLD_STANDALONE=ON -DTVD_LIM=VL -DPREC_EVAP=ON -DUSE_GOTM=ON -DGOTM_BASE=../gotm"
# ============================================================

# Activate MVAPICH2 if argument to this script is mvapich2 else if openmpi activate openmpi
if [ "$1" == "mvapich2" ]; then
  module load mpi/mvapich2
elif [ "$1" == "mvapich2-ndr-patch" ]; then
  module load gcc-9.2.0
  export PATH=$PATH:/opt/mvapich2-${MVAPICH2_VERSION}/bin
  export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/mvapich2-${MVAPICH2_VERSION}/lib
elif [ "$1" == "openmpi" ]; then
  module load mpi/openmpi
elif [ "$1" == "hpcx" ]; then
  module load mpi/hpcx
elif [ "$1" == "intelmpi" ]; then
  # Install Intel oneAPI
  # Remove Intel oneAPI if it exists
  rm -rf /opt/intel/oneapi

  cd /tmp
  curl -L ${URL_HPCKIT} -o ${URL_HPCKIT##*/} && chmod +x ${URL_HPCKIT##*/} && ./${URL_HPCKIT##*/} -a -c --silent --eula accept --components="intel.oneapi.lin.ifort-compiler:intel.oneapi.lin.dpcpp-cpp-compiler:intel.oneapi.lin.mpi.devel"
  source /opt/intel/oneapi/setvars.sh
else
  echo "Please provide either mvapich2 or openmpi or intelmpi as an argument to this script"
  exit 1
fi

# Set the compilers for MPI builds (used by SCHISM)
export MPI_CC=mpicc
export MPI_CXX=mpicxx
export MPI_FC=mpif90
# -fcheck=all -fno-omit-frame-pointer # for debugging only
export INFO_FLAGS="-g -fbacktrace"
if [ "$1" == "intelmpi" ]; then
  export MPI_CC=mpiicc
  export MPI_CXX=mpiicpc
  export MPI_FC=mpiifort
  export INFO_FLAGS="-g -traceback"
fi
# Use plain compilers for building libraries (HDF5, NetCDF) to avoid
# libtool embedding libmpi.la dependencies in .la files
export CC=gcc
export CXX=g++
export FC=gfortran
# Install dependencies
dnf install -y --nogpgcheck gcc gcc-c++ git procps-ng ncurses cmake python39 
dnf install -y --nogpgcheck curl-devel # libcurl-devel, libxml2-devel, zlib-devel, m4, and diffutils.

# Munge may be needed with a machine with Slurm to make OpenMPI work with Slurm
dnf install -y --nogpgcheck munge-devel
alternatives --set python /usr/bin/python3

# Install Azure CLI (needed for inline application package registration)
rpm --import https://packages.microsoft.com/keys/microsoft.asc
dnf install -y https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm
dnf install -y --nogpgcheck azure-cli

# Install HDF5
cd /tmp
TAR_HDF5=${URL_HDF5##*/}
curl -L ${URL_HDF5} -o ${TAR_HDF5}
if [[ -d "${TAR_HDF5%.tar.gz}" ]]; then
  rm -rf ${TAR_HDF5%.tar.gz}
fi
tar -xzf ${TAR_HDF5} && cd ${TAR_HDF5%.tar.gz} && mkdir -p build && cd build
# HDF5 ≥ 1.14.0 removed the Autotools configure script; use CMake instead.
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${PREFIX_HDF5} \
      -DHDF5_BUILD_FORTRAN=ON -DBUILD_SHARED_LIBS=ON \
      -DBUILD_TESTING=OFF -DHDF5_BUILD_TOOLS=OFF ..
make -j $(nproc) install

# Install NetCDF
cd /tmp
# GitHub archives extract as <repo>-<version> (no 'v' prefix), not the tag name
DIR_NETCDF="netcdf-c-${NETCDF_C_VERSION}"
TAR_NETCDF="${DIR_NETCDF}.tar.gz"
curl -L ${URL_NETCDF} -o ${TAR_NETCDF}
if [[ -d "${DIR_NETCDF}" ]]; then
  rm -rf ${DIR_NETCDF}
fi
tar -xzf ${TAR_NETCDF} && cd ${DIR_NETCDF} && mkdir build && cd build
LD_LIBRARY_PATH=${PREFIX_HDF5}/lib:$LD_LIBRARY_PATH CFLAGS=-I${PREFIX_HDF5}/include LDFLAGS=-L${PREFIX_HDF5}/lib LIBS="-lhdf5" ../configure --prefix=${PREFIX_NETCDF} && make -j $(nproc) install

# Install NetCDF-Fortran
cd /tmp
# GitHub archives extract as <repo>-<version> (no 'v' prefix), not the tag name
DIR_NETCDF_FORTRAN="netcdf-fortran-${NETCDF_FORTRAN_VERSION}"
TAR_NETCDF_FORTRAN="${DIR_NETCDF_FORTRAN}.tar.gz"
curl -L ${URL_NETCDF_FORTRAN} -o ${TAR_NETCDF_FORTRAN}
if [[ -d "${DIR_NETCDF_FORTRAN}" ]]; then
  rm -rf ${DIR_NETCDF_FORTRAN}
fi
tar -xzf ${TAR_NETCDF_FORTRAN} && cd ${DIR_NETCDF_FORTRAN} && mkdir build && cd build
LD_LIBRARY_PATH=${PREFIX_NETCDF}/lib:${PREFIX_HDF5}/lib:$LD_LIBRARY_PATH CFLAGS="-I${PREFIX_NETCDF}/include -I${PREFIX_HDF5}/include" LDFLAGS="-L${PREFIX_NETCDF}/lib -L${PREFIX_HDF5}/lib" LIBS="-lnetcdf -lhdf5" ../configure --prefix=${PREFIX_NETCDF_FORTRAN}
make -j $(nproc) install

# Install SCHISM - switch to MPI compilers
export CC=${MPI_CC}
export CXX=${MPI_CXX}
export FC=${MPI_FC}
cd /tmp
export LD_LIBRARY_PATH=${PREFIX_NETCDF_FORTRAN}/lib:${PREFIX_NETCDF}/lib:${PREFIX_HDF5}/lib:$LD_LIBRARY_PATH
export LDFLAGS="-L${PREFIX_NETCDF_FORTRAN}/lib -L${PREFIX_NETCDF}/lib -L${PREFIX_HDF5}/lib"
export LIBS="-lnetcdff -lnetcdf -lhdf5"
export PATH=${PREFIX_NETCDF_FORTRAN}/bin:${PREFIX_NETCDF}/bin:${PREFIX_HDF5}/bin:$PATH

# URL_SCHISM="https://github.com/schism-dev/schism/archive/refs/tags/v5.11.1.tar.gz"
# TAR_SCHISM=${URL_SCHISM##*/}
# curl -L ${URL_SCHISM} -o ${TAR_SCHISM}
# tar -xf ${TAR_SCHISM}
if [[ -d "schism" ]]; then
  rm -rf schism
fi
git clone -b $SCHISM_VERSION https://github.com/schism-dev/schism.git
cd schism

URL_GOTM="https://github.com/gotm-model/code/archive/refs/tags/${GOTM_VERSION}.tar.gz"
TAR_GOTM=${URL_GOTM##*/}
GOTM_NAME=${TAR_GOTM%.tar.gz}
curl -L ${URL_GOTM} -o ${TAR_GOTM}
tar -xf ${TAR_GOTM}
mv code-${GOTM_VERSION#v} gotm

# Fix the code to use ifx
sed -i 's/message(FATAL_ERROR "Preprocessor flag/message(STATUS "Preprocessor flag/g' src/CMakeLists.txt

cmake -E remove_directory build
cmake -E make_directory build
cd build

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" $CMAKE_BASE_FLAGS ../src
make -j $(nproc) pschism
if [ -f CMakeCache.txt ]; then
  rm CMakeCache.txt
fi

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" $CMAKE_BASE_FLAGS -DUSE_GEN=ON ../src
make -j $(nproc) pschism
if [ -f CMakeCache.txt ]; then
  rm CMakeCache.txt
fi

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" $CMAKE_BASE_FLAGS -DUSE_AGE=ON ../src
make -j $(nproc) pschism
if [ -f CMakeCache.txt ]; then
  rm CMakeCache.txt
fi

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" $CMAKE_BASE_FLAGS -DUSE_GEN=ON -DUSE_AGE=ON ../src
make -j $(nproc) pschism
if [ -f CMakeCache.txt ]; then
  rm CMakeCache.txt
fi

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" $CMAKE_BASE_FLAGS -DUSE_SED=ON ../src
make -j $(nproc) pschism
if [ -f CMakeCache.txt ]; then
  rm CMakeCache.txt
fi

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" $CMAKE_BASE_FLAGS -DUSE_SED=ON -DUSE_WWM=ON ../src
make -j $(nproc) pschism
if [ -f CMakeCache.txt ]; then
  rm CMakeCache.txt
fi

mkdir -p /opt/schism
cp bin/* /opt/schism

# package schism and dependencies into a zip package for azure batch
cd /tmp
cd /opt
cat << 'EOF' > schism/setup_paths.sh
# source this file to setup the paths
# Get the directory of the current script being sourced
SCHISM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
echo "SCHISM_HOME directory is: $SCHISM_HOME"
export NETCDF_C_HOME="${SCHISM_HOME}/../netcdf-c"
export NETCDF_FORTRAN_HOME="${SCHISM_HOME}/../netcdf-fortran"
export HDF5_HOME="${SCHISM_HOME}/../hdf5"
export LD_LIBRARY_PATH=${NETCDF_C_HOME}/lib:${NETCDF_FORTRAN_HOME}/lib:${HDF5_HOME}/lib:$LD_LIBRARY_PATH
export LDFLAGS="-L${NETCDF_C_HOME}/lib -L${NETCDF_FORTRAN_HOME}/lib -L${HDF5_HOME}/lib"
export LIBS="-lnetcdff -lnetcdf -lhdf5"
export PATH=${SCHISM_HOME}:${NETCDF_C_HOME}/bin:${NETCDF_FORTRAN_HOME}/bin:${HDF5_HOME}/bin:$PATH
EOF
#
# Use FULL_VERSION from the environment (set by the YAML job config) if available;
# fall back to a local calculation when running the script standalone.
export FULL_VERSION=${FULL_VERSION:-${SCHISM_VERSION}_${OSVER}_${1}}
echo "Full version: $FULL_VERSION"
zip -r /tmp/schism_with_deps_$FULL_VERSION.zip schism netcdf-c netcdf-fortran hdf5
# cp /tmp/schism_with_deps_$FULL_VERSION.zip .
# # Install azcli
#sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
#sudo dnf install -y https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm
#sudo dnf install azure-cli
#az --version
# # Done installing azcli, now upload the package to azure batch
# az login --use-device-code
# export BATCH_ACCOUNT="schismbatch"
# export BATCH_RESOURCE_GROUP="dwrbdo_schism_rg"
# export FULL_VERSION=${SCHISM_VERSION}_${OSVER}_${1}_{machine_type}
# az batch application package create --application-name schism_with_deps --name $BATCH_ACCOUNT --package-file schism_with_deps_$FULL_VERSION.zip -g $BATCH_RESOURCE_GROUP --version-name "$FULL_VERSION"
echo "Done building SCHISM with dependencies"
