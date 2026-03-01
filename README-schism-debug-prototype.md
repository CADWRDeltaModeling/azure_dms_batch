# Debugging and Prototyping Workflow for SCHISM Tasks

To effectively debug or prototype a SCHISM run (or any MPI-based Azure Batch task), use an interactive "dummy wait" strategy. This allows you to board the exact compute node where the job is deployed to troubleshoot environment issues or test command sequences in real-time.

## 1. Submit a Job with a "Dummy Wait"

The first step in prototyping is to submit your Batch job using a modified YAML configuration or command. Instead of executing the actual SCHISM run immediately, replace the primary command with a wait command.

- **Purpose:** This keeps the task in a "Running" state indefinitely, preventing Azure Batch from terminating the task and shutting down the compute node.
- **Cost Awareness:** Remember that while the node is "waiting," you are being charged for the compute time (e.g., approximately $4.00/hour for an H-series node).

## 2. Create a Remote User for Login

Once the node is in the "Running" state, you must create a user account to log in via SSH.

1. Navigate to the **Nodes** view in the Azure Portal or Azure Batch Explorer.
2. Select the specific node and click **Add User**.
3. **Configuration:** Specify a username and password. It is highly recommended to grant the user **Administrative (sudo)** privileges so you can manage root-level directories or install missing dependencies if needed.
4. **Expiry:** You can set an expiry time for the user (default is often 24 hours), after which the credentials will lapse.

## 3. Connect via VS Code (Remote - SSH)

Visual Studio Code is the preferred tool for interacting with the node because it allows you to edit files and run terminals directly on the remote Linux environment.

- **Host Information:** Obtain the **Public IP address** of the node from the Azure Portal.
- **SSH Configuration:** Add a new entry to your VS Code SSH configuration file:
  - **Host Name:** The node's IP address.
  - **User:** The username you just created.
- **Connection:** Open a new window and connect to the host. When prompted, select **Linux** as the platform and enter the password you specified earlier.

## 4. Setup the Environment and Repeat Commands

Once logged in, navigate to the task working directory, typically located under:

```
/mnt/batch/tasks/workitems/[job_id]/[task_id]/wd
```

To replicate the automated Azure Batch environment and setup, execute the following scripts in order:

1. **Source `env_vars.sh`:** This is a critical first step. Sourcing this file loads all necessary environment variables, module paths, and application settings required for SCHISM and MPI.
   ```bash
   source env_vars.sh
   ```

2. **Use `coordination_command.sh`:** Run this script to repeat the multi-node setup steps, such as configuring the host file for MPI and ensuring all nodes in the cluster are synchronized.
   ```bash
   bash coordination_command.sh
   ```

3. **Use `application_command.sh`:** This script contains the actual execution logic. By running or modifying this script, you can manually trigger `azcopy` commands to bring in data or test the `mpirun` command with specific flags.
   ```bash
   bash application_command.sh
   ```

## 5. Cleanup

Because the "wait" process keeps the node active, the pool will not automatically scale down. Once your prototyping is complete, you must **manually delete the job** or **resize the pool to zero** to stop the billing.
