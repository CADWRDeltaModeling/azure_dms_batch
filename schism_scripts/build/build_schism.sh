#!/bin/bash
# assumes root user is running this script. 
# Build all from a clean (Almalinx) Linux machine
set -e
#
export SCHISM_VERSION="v5.11.1"
export OSVER="alma8.7hpc"
# Activate MVAPICH2 if argument to this script is mvapich2 else if openmpi activate openmpi
if [ "$1" == "mvapich2" ]; then
  module load mpi/mvapich2
elif [ "$1" == "openmpi" ]; then
  module load mpi/openmpi
elif [ "$1" == "hpcx" ]; then
  module load mpi/hpcx
elif [ "$1" == "intelmpi" ]; then
  # Install Intel oneAPI
  # Remove Intel oneAPI if it exists
  rm -rf /opt/intel/oneapi

  cd /tmp
  URL_HPCKIT=https://registrationcenter-download.intel.com/akdlm/IRC_NAS/7f096850-dc7b-4c35-90b5-36c12abd9eaa/l_HPCKit_p_2024.1.0.560.sh
  curl -L ${URL_HPCKIT} -o ${URL_HPCKIT##*/} && chmod +x ${URL_HPCKIT##*/} && ./${URL_HPCKIT##*/} -a -c --silent --eula accept --components="intel.oneapi.lin.ifort-compiler:intel.oneapi.lin.dpcpp-cpp-compiler:intel.oneapi.lin.mpi.devel"
  source /opt/intel/oneapi/setvars.sh
else
  echo "Please provide either mvapich2 or openmpi or intelmpi as an argument to this script"
  exit 1
fi

# Set the compilers
export CC=mpicc
export CXX=mpicxx
export FC=mpif90
# -fcheck=all -fno-omit-frame-pointer # for debugging only
export INFO_FLAGS="-g -fbacktrace"
if [ "$1" == "intelmpi" ]; then
  export CC=mpiicc
  export CXX=mpiicpc
  export FC=mpiifort
  export INFO_FLAGS="-g -traceback"
fi
# Install dependencies
dnf install -y --nogpgcheck gcc gcc-c++ git procps-ng ncurses cmake python39 
dnf install -y --nogpgcheck curl-devel # libcurl-devel, libxml2-devel, zlib-devel, m4, and diffutils.

# Munge may be needed with a machine with Slurm to make OpenMPI work with Slurm
dnf install -y --nogpgcheck munge-devel
alternatives --set python /usr/bin/python3

# Install HDF5
cd /tmp
PREFIX_HDF5=/opt/hdf5
URL_HDF5="https://hdf-wordpress-1.s3.amazonaws.com/wp-content/uploads/manual/HDF5/HDF5_1_14_3/src/hdf5-1.14.3.tar.gz"
TAR_HDF5=${URL_HDF5##*/}
curl -L ${URL_HDF5} -o ${TAR_HDF5}
if [[ -d "${TAR_HDF5%.tar.gz}" ]]; then
  rm -rf ${TAR_HDF5%.tar.gz}
fi
tar -xzf ${TAR_HDF5} && cd ${TAR_HDF5%.tar.gz} && mkdir build && cd build
../configure --prefix=${PREFIX_HDF5} --enable-fortran
make -j $(nproc) install

# Install NetCDF
cd /tmp
PREFIX_HDF5=/opt/hdf5
PREFIX_NETCDF=/opt/netcdf-c
URL_NETCDF="https://downloads.unidata.ucar.edu/netcdf-c/4.9.2/netcdf-c-4.9.2.tar.gz"
TAR_NETCDF=${URL_NETCDF##*/}
curl -L ${URL_NETCDF} -o ${TAR_NETCDF}
if [[ -d "${TAR_NETCDF%.tar.gz}" ]]; then
  rm -rf ${TAR_NETCDF%.tar.gz}
fi
tar -xzf ${TAR_NETCDF} && cd ${TAR_NETCDF%.tar.gz} && mkdir build && cd build
LD_LIBRARY_PATH=${PREFIX_HDF5}/lib:$LD_LIBRARY_PATH CFLAGS=-I${PREFIX_HDF5}/include LDFLAGS=-L${PREFIX_HDF5}/lib LIBS="-lhdf5" ../configure --prefix=${PREFIX_NETCDF} && make -j $(nproc) install

# Install NetCDF-Fortran
cd /tmp
PREFIX_HDF5=/opt/hdf5
PREFIX_NETCDF=/opt/netcdf-c
PREFIX_NETCDF_FORTRAN=/opt/netcdf-fortran
URL_NETCDF_FORTRAN="https://downloads.unidata.ucar.edu/netcdf-fortran/4.6.1/netcdf-fortran-4.6.1.tar.gz"
TAR_NETCDF_FORTRAN=${URL_NETCDF_FORTRAN##*/}
curl -L ${URL_NETCDF_FORTRAN} -o ${TAR_NETCDF_FORTRAN}
if [[ -d "${TAR_NETCDF_FORTRAN%.tar.gz}" ]]; then
  rm -rf ${TAR_NETCDF_FORTRAN%.tar.gz}
fi
tar -xzf ${TAR_NETCDF_FORTRAN} && cd ${TAR_NETCDF_FORTRAN%.tar.gz} && mkdir build && cd build
LD_LIBRARY_PATH=${PREFIX_NETCDF}/lib:${PREFIX_HDF5}/lib:$LD_LIBRARY_PATH CFLAGS="-I${PREFIX_NETCDF}/include -I${PREFIX_HDF5}/include" LDFLAGS="-L${PREFIX_NETCDF}/lib -L${PREFIX_HDF5}/lib" LIBS="-lnetcdf -lhdf5" ../configure --prefix=${PREFIX_NETCDF_FORTRAN}
make -j $(nproc) install

# Install SCHISM
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

URL_GOTM="https://github.com/gotm-model/code/archive/refs/tags/v5.2.1.tar.gz"
TAR_GOTM=${URL_GOTM##*/}
GOTM_NAME=${TAR_GOTM%.tar.gz}
curl -L ${URL_GOTM} -o ${TAR_GOTM}
tar -xf ${TAR_GOTM}
mv code-5.2.1 gotm

# Fix the code to use ifx
sed -i 's/message(FATAL_ERROR "Preprocessor flag/message(STATUS "Preprocessor flag/g' src/CMakeLists.txt

cmake -E remove_directory build
cmake -E make_directory build
cd build

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" -DTVD_LIM=VL -DPREC_EVAP=ON -DUSE_GOTM=ON -DGOTM_BASE=../gotm ../src
make -j $(nproc)

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" -DTVD_LIM=VL -DPREC_EVAP=ON -DUSE_GOTM=ON -DGOTM_BASE=../gotm -DUSE_GEN=ON ../src
make -j $(nproc) pschism

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" -DTVD_LIM=VL -DPREC_EVAP=ON -DUSE_GOTM=ON -DGOTM_BASE=../gotm -DUSE_AGE=ON ../src
make -j $(nproc) pschism

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" -DTVD_LIM=VL -DPREC_EVAP=ON -DUSE_GOTM=ON -DGOTM_BASE=../gotm -DUSE_GEN=ON -DUSE_AGE=ON ../src
make -j $(nproc) pschism

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" -DTVD_LIM=VL -DPREC_EVAP=ON -DUSE_GOTM=ON -DGOTM_BASE=../gotm -DUSE_SED=ON ../src
make -j $(nproc) pschism

cmake -DCMAKE_Fortran_FLAGS_INIT="$INFO_FLAGS" -DTVD_LIM=VL -DPREC_EVAP=ON -DUSE_GOTM=ON -DGOTM_BASE=../gotm -DUSE_SED=ON -DUSE_WWM=ON ../src
make -j $(nproc) pschism

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
export FULL_VERSION=${SCHISM_VERSION}_${OSVER}_${1}
echo "Full version: $FULL_VERSION"
zip -r /tmp/schism_with_deps_$FULL_VERSION.zip schism netcdf-c netcdf-fortran hdf5
# export $BATCH_ACCOUNT="schismbatch"
# export $BATCH_RESOURCE_GROUP="dwrbdo_schism_rg"
# az batch application package create --application-name schism_with_deps --name $BATCH_ACCOUNT --package-file /tmp/schism_with_deps_$FULL_VERSION.zip -g $BATCH_RESOURCE_GROUP --version-name "$FULL_VERSION"
echo "Done building SCHISM with dependencies"
