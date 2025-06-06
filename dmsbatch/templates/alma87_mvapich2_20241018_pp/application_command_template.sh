echo Main task $(pwd);
source /usr/share/Modules/init/bash;
printenv;
module load mpi/mvapich2;
if [[ -z $AZ_BATCH_APP_PACKAGE_schimpy_with_deps ]]; then
    echo "schimpy_with_deps package not found"
else 
    source $AZ_BATCH_APP_PACKAGE_schimpy_with_deps/bin/activate;
fi
source $AZ_BATCH_APP_PACKAGE_schism_with_deps/schism/setup_paths.sh;
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup;
export BAY_DELTA_SCHISM_HOME=$AZ_BATCH_APP_PACKAGE_baydeltaschism;
ulimit -s unlimited;
#
echo "Copying from blob to local for the setup first time";
cd $AZ_BATCH_TASK_WORKING_DIR; # make sure to match this to the coordination command template
# do setup directories first to avoid link issues 
setup_dirs="{setup_dirs}";
setup_dirs=(${{setup_dirs//[\[\],]/ }});
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
# run commands
# run commands with output to multiple files using tee and process substitution
run_commands() {{
{command}
}}
set +e;
run_commands 2> >(tee -a "$AZ_BATCH_TASK_DIR/stderr_command.txt" >&2) > >(tee -a "$AZ_BATCH_TASK_DIR/stdout_command.txt");
set -e;
exit_code=${{PIPESTATUS[0]}}; 
echo Run Done;
# wait for background copy to finish
wait;
# no semicolon for last command
exit $exit_code