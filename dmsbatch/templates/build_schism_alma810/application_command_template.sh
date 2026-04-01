# Build task — single node, no NFS, no study dir setup, runs as admin
echo "Build task starting on $(hostname) at $(date)";
source /usr/share/Modules/init/bash;
printenv;
module load mpi/mvapich2;
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup;
ulimit -s unlimited;

# Run the build command (defined in job YAML)
run_commands() {{
{command}
}}
set +e;
run_commands 2> >(tee -a "$AZ_BATCH_TASK_DIR/stderr_command.txt" >&2) > >(tee -a "$AZ_BATCH_TASK_DIR/stdout_command.txt");
set -e;
exit_code=${{PIPESTATUS[0]}};
echo "Build task done with exit code $exit_code at $(date)";
# no semicolon for last command
exit $exit_code
