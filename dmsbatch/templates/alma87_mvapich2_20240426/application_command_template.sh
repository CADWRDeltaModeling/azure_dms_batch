echo Main task $(pwd);
source /usr/share/Modules/init/bash;
printenv;
export SCHISM_STUDY_DIR=$AZ_BATCH_TASK_WORKING_DIR/simulations/{study_dir};
telegraf --config $AZ_BATCH_APP_PACKAGE_telegraf/telegraf.conf > /dev/null 2>&1 &
telegraf_pid=$!;
module load mpi/mvapich2;
source $AZ_BATCH_APP_PACKAGE_schimpy_with_deps/bin/activate;
source $AZ_BATCH_APP_PACKAGE_schism_with_deps/schism/setup_paths.sh;
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup;
export BAY_DELTA_SCHISM_HOME=$AZ_BATCH_APP_PACKAGE_baydeltaschism;
ulimit -s unlimited;
#
echo "Copying from blob to local for the setup first time";
cd $AZ_BATCH_TASK_WORKING_DIR/simulations; # make sure to match this to the coordination command template
# do setup directories first to avoid link issues 
setup_dirs=({setup_dirs});
# loop over a array of directories, note double braces to escape for f-string substitution via python
for dir in "${{setup_dirs[@]}}"; do
    echo "Copying $dir";
    mkdir -p $(dirname $dir);
    azcopy copy {setup_dirs_copy_flags} "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/$dir?{sas}" $(dirname $dir) || true;
done

# setup study directory
mkdir -p $(dirname {study_dir});
azcopy copy {study_copy_flags} "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{study_dir}?{sas}" $(dirname {study_dir}) || true;
mkdir -p {study_dir}/outputs;

# change to study directory
cd {study_dir};
# start background copy script
SAS="{sas}" bash $SCHISM_SCRIPTS_HOME/batch/copy_modified_loop.sh -d {delete_after_mins} {study_dir} $AZ_BATCH_NODE_MOUNTS_DIR "{storage_account_name}" "{storage_container_name}"&
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
# run commands
echo "Running command with {num_cores} cores and {num_hosts} hosts";
# run commands with output to multiple files using tee and process substitution
run_commands() {{
{mpi_command}
}}
set +e;
run_commands | tee -a >(cat >> $AZ_BATCH_TASK_DIR/stdout_command.txt) >(cat >> $AZ_BATCH_TASK_DIR/stdout.txt) 2>&1 | tee -a >(cat >> $AZ_BATCH_TASK_DIR/stderr_command.txt) >(cat >> $AZ_BATCH_TASK_DIR/stderr.txt) >&2;
set -e;
exit_code=${{PIPESTATUS[0]}}; 
echo Run Done;
echo "Sending signal to background copy_modified_loop.sh with pid $pid";
kill -SIGUSR1 $pid;
kill $telegraf_pid;
# wait for background copy to finish
wait;
echo "Done with everything. Shutting down";
# no semicolon for last command
exit $exit_code
