echo Main task $(pwd);
source /usr/share/Modules/init/bash;
printenv;
export SCHISM_STUDY_DIR=$AZ_BATCH_TASK_WORKING_DIR/simulations/{study_dir};
source /opt/intel/oneapi/setvars.sh;
export PATH=/opt/openmpi-5.0.2/bin/:$PATH;
export LD_LIBRARY_PATH=/opt/openmpi-5.0.2/lib/:$LD_LIBRARY_PATH;
source $AZ_BATCH_APP_PACKAGE_schimpy_with_deps_rhel8_7/bin/activate;
source $AZ_BATCH_APP_PACKAGE_schism_with_deps_5_11_alma8_7hpc_ucx_5_0_2/schism/setup_paths.sh;
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup_alma8_7;
export BAY_DELTA_SCHISM_HOME=$AZ_BATCH_APP_PACKAGE_BayDeltaSCHISM_2024_06_27;
ulimit -s unlimited;
#
echo "Copying from blob to local for the setup first time";
cd $AZ_BATCH_TASK_WORKING_DIR; # make sure to match this to the coordination command template
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
# run commands
# run commands with output to multiple files using tee and process substitution
run_commands() {{
{mpi_command}
}}
set +e;
run_commands | tee -a >(cat >> $AZ_BATCH_TASK_DIR/stdout_command.txt) >(cat >> $AZ_BATCH_TASK_DIR/stdout.txt) 2>&1 | tee -a >(cat >> $AZ_BATCH_TASK_DIR/stderr_command.txt) >(cat >> $AZ_BATCH_TASK_DIR/stderr.txt) >&2;
set -e;
exit_code=${{PIPESTATUS[0]}}; 
echo Run Done;
wait;
# no semicolon for last command
exit $exit_code