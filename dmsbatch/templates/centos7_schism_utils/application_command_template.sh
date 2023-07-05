echo Main task $(pwd);
source /usr/share/Modules/init/bash;
source /opt/intel/oneapi/setvars.sh intel64; # seems to conflict with the installed modules, try again with custom image
export SCHISM_VERSION="5.10.1";
export NETCDF_C_VERSION="4.9.2";
export NETCDF_FORTRAN_VERSION="4.5.3"
export HDF5_VERSION="1.14.0";
# if the versions above are set then the following can be used
export PATH=$PATH:/opt/netcdf-c/${{NETCDF_C_VERSION}}/bin/:/opt/netcdf-fortran/${{NETCDF_FORTRAN_VERSION}}/bin/:/opt/hdf5/${{HDF5_VERSION}}/bin/:/opt/schism/${{SCHISM_VERSION}}/;
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/netcdf-c/${{NETCDF_C_VERSION}}/lib/:/opt/netcdf-fortran/${{NETCDF_FORTRAN_VERSION}}/lib/:/opt/hdf5/${{HDF5_VERSION}}/lib/:/opt/schism/${{SCHISM_VERSION}}/lib/;
ulimit -s unlimited;
# already loaded by oneapi sourcing but cause segfault. Needs recompilation
module load mpi/impi-2021;
echo "Copying from blob to local for the setup first time";
cd $AZ_BATCH_TASK_WORKING_DIR/simulations; # make sure to match this to the coordination command template
# setup study directory
mkdir -p $(dirname {study_dir});
azcopy cp "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{study_dir}?{sas}" $(dirname {study_dir}) --recursive --preserve-symlinks --exclude-regex=".*outputs.*/.*nc" || true;

# add in other directories
setup_dirs=({setup_dirs});
# loop over a array of directories, note double braces to escape for f-string substitution via python
for dir in "${{setup_dirs[@]}}"; do
    echo "Copying $dir";
    mkdir -p $(dirname $dir);
    azcopy cp "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/$dir?{sas}" $(dirname $dir) --recursive --preserve-symlinks || true;
done
# change to study directory
cd {study_dir};
# start background copy script
SAS="{sas}" bash /opt/schism_scripts/batch/copy_modified_loop.sh {study_dir} $AZ_BATCH_NODE_MOUNTS_DIR "{storage_account_name}" "{storage_container_name}"& 
pid=$!;
echo "Running background copy_modified_loop.sh with pid $pid";
# run schism
echo "Running schism with {num_cores} cores and {num_hosts} hosts";
export I_MPI_FABRICS=shm:ofi;
export I_MPI_OFI_PROVIDER=mlx;
{mpi_command};
echo Util Run Done;
sleep 300;
echo "Killing background copy_modified_loop.sh with pid $pid";
kill $pid;
# no semicolon for last command
echo "Done with everything. Shutting down"