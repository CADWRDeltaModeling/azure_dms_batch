echo Main task $(pwd);
printenv;
echo "Copying from blob to local for the setup first time";
run_commands() {{
{command}
}}
set +e;
run_commands 2> >(tee -a "$AZ_BATCH_TASK_DIR/stderr_command.txt" >&2) > >(tee -a "$AZ_BATCH_TASK_DIR/stdout_command.txt")
set -e;
exit_code=${{PIPESTATUS[0]}}; 
echo Run Done;
wait;
echo "Done with everything. Shutting down";
# no semicolon for last command
exit $exit_code
