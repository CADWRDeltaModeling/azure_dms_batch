#!/bin/bash
# schism release identifier. E.g. schism_release="schismv5.10.1". Used with name of the url from github release
# schism_file="schism_5_10_1_alma_8_5_HPC_gen1"
# E.g. 
# https://github.com/CADWRDeltaModeling/azure_dms_batch/releases/download/${schism_release}/${schism_file}.tar.gz

# Default values for flags
uselatest=true
export LOCAL_INSTALL_DIR="/tmp/localinstalls"

if [ -v USE_CACHED_INSTALL ]; then
  echo "Using cached install"
else
  echo "Using online install"
fi

# Parse named arguments using getopts
while getopts ":r" opt; do
  case $opt in
    r)
      uselatest=false # use release if -r is passed
      ;;
    *)
      echo "Unknown parameter passed: $OPTARG"
      exit 1
      ;;
  esac
done

# Shift the named arguments
shift $((OPTIND - 1))

# Access and use the arguments
schism_release="$1"
schism_file="$2"
pushd /tmp || exit
mkdir -p ${LOCAL_INSTALL_DIR}

mkdir -p /opt
if [ "$uselatest" = true ]; then
  echo "Using latest scripts from github"
    # temporary way to get latest code into the pool
    if [ -v GIT_BRANCH ]; then
      echo "Using branch ${GIT_BRANCH}"
    else
      GIT_BRANCH="main"
      echo "Using branch ${GIT_BRANCH}"
    fi
    [[ ! -v USE_CACHED_INSTALL ]] && wget https://github.com/CADWRDeltaModeling/azure_dms_batch/archive/refs/heads/${GIT_BRANCH}.zip -O ${LOCAL_INSTALL_DIR}/${GIT_BRANCH}.zip
    (cd ${LOCAL_INSTALL_DIR}; unzip ${GIT_BRANCH}.zip; mv azure_dms_batch-${GIT_BRANCH}/schism_scripts /opt; rm -rf azure_dms_batch-${GIT_BRANCH})
else
  echo "Using scripts from release ${schism_release}"
    [[ ! -v USE_CACHED_INSTALL ]] && wget "https://github.com/CADWRDeltaModeling/azure_dms_batch/archive/refs/tags/${schism_release}.tar.gz" -O ${LOCAL_INSTALL_DIR}/${schism_release}.tar.gz
    (cd ${LOCAL_INSTALL_DIR}; tar xvzf "${schism_release}.tar.gz";  mv "azure_dms_batch-${schism_release}/schism_scripts" /opt; rm -rf azure_dms_batch-${schism_release})
fi
#
pushd /opt/schism_scripts/batch || exit
chmod +x *.sh
# Now in /opt/schism_scripts/batch for the rest of the scripts
./enable_sudo_for_batch.sh
echo "Starting pool install script..."
./install-azcopy.sh
echo "Starting Intel oneAPI installation..."
./setup_intel_schism.sh "2021.4.0.x86_64"
echo "Starting NFS installation..."
./nfs_install.sh
echo "Done with NFS install"
echo "Starting insights installation..."
./appinsights_install.sh "v1.3.0"
./appinsights_start.sh
echo "Done enabling insights"
echo "Done with pool installs"
#
echo "Starting SCHISM installation..."
(source ./schism_install.sh; install_schism "$schism_release" "$schism_file")
echo "Done with SCHISM install"
popd
popd
echo "Done with pool setup script"
