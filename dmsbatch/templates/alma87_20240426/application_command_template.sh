echo Main task $(pwd);
source /usr/share/Modules/init/bash;
source /opt/intel/oneapi/setvars.sh;
export PATH=/opt/openmpi-5.0.2/bin/:$PATH;
export LD_LIBRARY_PATH=/opt/openmpi-5.0.2/lib/:$LD_LIBRARY_PATH;
source $AZ_BATCH_APP_PACKAGE_schism_with_deps_5_11_alma8_7hpc_ucx_5_0_2/schism/setup_paths.sh;
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup_alma8_7;
ulimit -s unlimited;
printenv;
#
echo "Copying from blob to local for the setup first time";
cd $AZ_BATCH_TASK_WORKING_DIR/simulations; # make sure to match this to the coordination command template
# do setup directories first to avoid link issues 
setup_dirs=({setup_dirs});
# loop over a array of directories, note double braces to escape for f-string substitution via python
for dir in "${{setup_dirs[@]}}"; do
    echo "Copying $dir";
    mkdir -p $(dirname $dir);
    azcopy copy --recursive --preserve-symlinks "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/$dir?{sas}" $(dirname $dir) || true;
done

# setup study directory
mkdir -p $(dirname {study_dir});
azcopy copy {study_copy_flags} "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{study_dir}?{sas}" $(dirname {study_dir}) || true;
mkdir -p {study_dir}/outputs;

# change to study directory
cd {study_dir};
# start background copy script
SAS="{sas}" bash $SCHISM_SCRIPTS_HOME/batch/copy_modified_loop.sh {study_dir} $AZ_BATCH_NODE_MOUNTS_DIR "{storage_account_name}" "{storage_container_name}"&
pid=$!;
echo "Running background copy_modified_loop.sh with pid $pid";
# Extract host list from AZ_BATCH_HOST_LIST
IFS=',' read -r -a host_list <<< "$AZ_BATCH_HOST_LIST"

# Create hostfile
hostfile="hostfile"
for host in "${{host_list[@]}}"; do
    echo "$host" >> "$hostfile"
done

echo "Hostfile created: $hostfile"
# run schism
echo "Running schism with {num_cores} cores and {num_hosts} hosts";
# allow script to continue if schism fails
set +e;
{mpi_command} >  $AZ_BATCH_TASK_DIR/stdout_command.txt 2> $AZ_BATCH_TASK_DIR/stderr_command.txt;
set -e;
exit_code=$?;
echo Schism Run Done;
echo "Sending signal to background copy_modified_loop.sh with pid $pid";
kill -SIGUSR1 $pid;
# no semicolon for last command
sleep 300;
wait;
echo "Done with everything. Shutting down";
exit $exit_code
