echo Main task $(pwd);
printenv;
echo "Copying from blob to local for the setup first time";
run_commands() {{
{command}
}}
set +e;
run_commands | tee -a >(cat >> $AZ_BATCH_TASK_DIR/stdout_command.txt) >(cat >> $AZ_BATCH_TASK_DIR/stdout.txt) 2>&1 | tee -a >(cat >> $AZ_BATCH_TASK_DIR/stderr_command.txt) >(cat >> $AZ_BATCH_TASK_DIR/stderr.txt) >&2;
set -e;
exit_code=${{PIPESTATUS[0]}}; 
echo Run Done;
wait;
echo "Done with everything. Shutting down";
# no semicolon for last command
exit $exit_code
