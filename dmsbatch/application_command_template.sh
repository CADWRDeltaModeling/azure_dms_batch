echo Main task $(pwd);
source /usr/share/Modules/init/bash;
source /opt/intel/oneapi/setvars.sh intel64; # seems to conflict with the installed modules, try again with custom image
export PATH=$PATH:/opt/netcdf-c/4.8.1/bin/:/opt/netcdf-fortran/4.5.3/bin/:/opt/hdf5/1.10.8/bin/:/opt/schism/5.10.0/;
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/netcdf-c/4.8.1/lib/:/opt/netcdf-fortran/4.5.3/lib/:/opt/hdf5/1.10.8/lib/:/opt/schism/5.10.0/lib/;
ulimit -s unlimited;
# already loaded by oneapi sourcing but cause segfault. Needs recompilation
module load mpi/impi-2021;
echo "Copying from blob to local for the setup first time";
cd $AZ_BATCH_TASK_WORKING_DIR/simulations; # make sure to match this to the coordination command template
# setup study directory
mkdir -p $(dirname {study_dir});
rsync -av --exclude="outputs/" --no-perms $AZ_BATCH_NODE_MOUNTS_DIR/{study_dir} $(dirname {study_dir});
mkdir -p {study_dir}/outputs;
# add in other directories
setup_dirs=({setup_dirs});
# loop over a array of directories, note double braces to escape for f-string substitution via python
for dir in "${{setup_dirs[@]}}"; do
    echo "Copying $dir";
    mkdir -p $(dirname $dir);
    rsync -av --exclude="outputs/" --no-perms $AZ_BATCH_NODE_MOUNTS_DIR/$dir $(dirname $dir);
done
# start background copy script
bash $AZ_BATCH_NODE_MOUNTS_DIR/batch/copy_modified_loop.sh {study_dir} $AZ_BATCH_NODE_MOUNTS_DIR& 
pid=$!;
echo "Running background copy_modified_loop.sh with pid $pid";
#
cd {study_dir};
echo "Running schism with {num_cores} cores and {num_hosts} hosts";
export I_MPI_FABRICS=shm:ofi;
export I_MPI_OFI_PROVIDER=mlx;
{mpi_command};
echo Schism Run Done;
sleep 300;
echo "Killing background copy_modified_loop.sh with pid $pid";
kill $pid;
# no semicolon for last command
echo "Done with everything. Shutting down"