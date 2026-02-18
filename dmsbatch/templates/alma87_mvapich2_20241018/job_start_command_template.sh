echo "Job Start Task Start"
# Add alias to /etc/bash.bashrc
sudo bash -c "echo 'alias swd=$AZ_BATCH_JOB_PREP_WORKING_DIR' >> /etc/bash.bashrc"
echo "Job Start Task Done"