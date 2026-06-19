---
marp: true
theme: default
paginate: true
style: |
  section {
    font-size: 1.4rem;
  }
  code {
    font-size: 0.95rem;
  }
  pre {
    font-size: 0.9rem;
  }
  h1 { color: #0078d4; }
  h2 { color: #005a9e; }
  .warn {
    background: #fff4ce;
    border-left: 4px solid #f0a500;
    padding: 0.4rem 0.8rem;
    margin-top: 0.5rem;
  }
  .columns {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1rem;
  }
---

# Interactive SCHISM on the Azure Batch Head Node

### Find → Connect → Source → Run

Debug and prototype SCHISM runs without re-submitting a job

---

## Agenda

> **Bring your laptop** if you want to follow along interactively.

1. **Keep the pool alive** — dummy-wait or fix pool size
2. **Find the head node** — via **Batch Explorer** *(recommended)*
3. **Create a remote user** — via **Batch Explorer** *(recommended)*
4. **Connect** — VS Code Remote-SSH with SSH keys *(recommended)*
5. **Connect** — plain SSH / password as fallback
6. **Terminal multiplexing** — tmux / multiple logins
7. **Load the environment** — source the right parts of the scripts
8. **Install tools** — nano, tmux on the node
9. **Run SCHISM interactively** — iterate on `param.nml`
10. **Cleanup** — stop billing immediately

> Steps 2–3 use **Batch Explorer** throughout. Portal and CLI alternatives are noted on each slide for reference.

---

## Step 1 — Keep the Pool Alive

### Option A: Dummy-wait (plan ahead)

If you know in advance you want an interactive session, replace your  
run command with a sleep before submitting:

```yaml
# schism_job_config.yml  (excerpt)
command: |
  sleep 86400   # keep task running up to 24 hours
```
```bash
dmsbatch schism submit-job --file schism_job_config.yml
```

### Option B: Fix pool size after job starts (most common)

Submit your **normal** job. Once the pool allocates all nodes, change  
the pool to a **fixed size** (matching the number of allocated nodes).  
This prevents auto-scale from shrinking the pool when the task ends.

> Azure Portal → Pools → select pool → **Scale** →  
> set mode to **Fixed** and *Dedicated nodes* = current allocation

---

## Step 1b — Cost Warning ⚠️

<div class="warn">

**You are billed for every minute the pool is running.**

- H-series nodes cost ~$4/hr each
- A 4-node pool ≈ $16/hr
- Fixing pool size keeps nodes running indefinitely — **shut down as soon as you are done**

</div>

**Always clean up when finished:**
- Azure Portal → Pools → **Scale** → set *Dedicated nodes* to **0**
- or: Azure Batch Explorer → Jobs → **Terminate/Delete**
- or via CLI:
  ```bash
  az batch pool resize --pool-id <pool> --target-dedicated-nodes 0 \
      --account-name <batch_account> \
      --account-endpoint https://<batch_account>.<region>.batch.azure.com
  ```

---

## Step 2 — Find the Head Node (Batch Explorer)

### Recommended: Azure Batch Explorer

**Via Jobs** *(easiest — head node shown directly)*

1. Open **Batch Explorer** → select your Batch account
2. Go to **Jobs** → select your job → select the running **Task**
3. The head node's IP address is displayed in the **top-right corner** of the task detail pane

**Via Pools** *(alternative)*

1. Navigate **Pools** → select your pool → **Nodes** tab
2. Find the node whose state is **Running** — the **IP address** is shown in the list

> **Which node is the head node?**  
> The head node is the one where `AZ_BATCH_IS_CURRENT_NODE_MASTER = true`.  
> The task detail pane in Batch Explorer displays this node at the top right when the task is running.

*Alternative — Azure Portal:* Batch Account → Pools → pool → Nodes → click node → copy Public IP.  
*Alternative — CLI:* `az batch node list --pool-id <pool>` and look for the running task node.

---

## Step 3 — Create a Remote User (Batch Explorer)

### Recommended: Azure Batch Explorer

1. **Pools** → select pool → **Nodes** → select the head node
2. Click the **Add/Update User** button in the node detail pane
3. Fill in:
   - **Username** — `batch-explorer-user`
   - **SSH public key** — paste contents of `~/.ssh/schism_batch.pub` *(see SSH key slides)*
   - **Admin** — ✅ enable (required to access `/mnt/batch/`)
   - **Expiry** — default 24 h; extend if needed
4. Click **Save**

> Repeat for any worker nodes if you need to SSH into them for debugging.

*Alternative — Azure Portal:* Batch Account → Pools → pool → Nodes → select node → **Add User** → same fields.  
*Alternative — CLI:* `az batch node user create --pool-id <pool> --node-id <node> --name batch-explorer-user --ssh-public-key "$(cat ~/.ssh/schism_batch.pub)" --is-admin true`

---

## Step 4 — SSH Key Setup in Azure (Recommended)

Password login works but SSH keys are more secure and avoid  
re-typing passwords with VS Code Remote-SSH.

### 1. Generate a key pair (on your local machine)

```bash
ssh-keygen -t ed25519 -C "schism-batch" -f ~/.ssh/schism_batch
# Creates: ~/.ssh/schism_batch  (private)
#          ~/.ssh/schism_batch.pub  (public)
```

### 2. Copy the public key content

```bash
cat ~/.ssh/schism_batch.pub
# ssh-ed25519 AAAA... schism-batch
```

---

## Step 4b — SSH Key Setup in Azure (continued)

### 3. Add user with the SSH public key

**Azure Portal** — when adding the user, paste the public key into  
the **SSH public key** field instead of setting a password.

**Azure Batch Explorer** — select the node → click **Add/Update User** button → paste the public key into the SSH public key field.

**Azure CLI:**
```bash
az batch node user create \
  --pool-id <pool-id> \
  --node-id <node-id> \
  --name batch-explorer-user \
  --ssh-public-key "$(cat ~/.ssh/schism_batch.pub)" \
  --is-admin true \
  --account-name <batch_account> \
  --account-endpoint https://<batch_account>.<region>.batch.azure.com
```

---

## Step 4c — SSH Key Setup in Azure (continued)

### 4. Configure `~/.ssh/config` on your local machine

```
Host schism-head
    HostName      <head-node-public-ip-address>
    Port          50000
    User          batch-explorer-user
    IdentityFile  "C:\Users\<your-username>\OneDrive <your-org>\ssh_keys\schism_batch"
    StrictHostKeyChecking no
```

> `StrictHostKeyChecking no` is convenient here because Batch nodes  
> are ephemeral — their host keys change between pool allocations.

### 5. Test the connection

```bash
ssh schism-head
# Should log in without a password prompt
```

---

## Step 5 — Connect via VS Code Remote-SSH

With the SSH config in place, connecting from VS Code is seamless:

1. Install the **Remote - SSH** extension if not already present
2. Press **F1** → *Remote-SSH: Connect to Host…* → select `schism-head`
3. Select **Linux** as the platform when prompted
4. VS Code installs its server component on the node (first time only)
5. Open a **Terminal** in VS Code — you are now running on the head node
6. Open the task working directory as a folder for easy file editing:
   - **File → Open Folder…**
   - `/mnt/batch/tasks/workitems/<job_id>/<task_id>/wd`

> You can edit `param.nml` directly in the VS Code editor with  
> syntax highlighting, no terminal editor needed.

---

## Step 5b — Add the Batch Tasks Folder to VS Code

Once connected, add `/mnt/batch/tasks` as a workspace folder so you  
can browse all jobs, tasks, and working directories from the Explorer pane.

1. In VS Code, go to **File → Add Folder to Workspace…**
2. Type or paste `/mnt/batch/tasks` and click **OK**
3. The folder appears in the Explorer — expand it to navigate:
   ```
   tasks/
   └── workitems/
       └── <job_id>/
           └── job-1/
               └── <task_id>/
                   └── wd/       ← working directory
                       ├── env_vars.sh
                       ├── application_command.sh
                       └── ...
   ```
4. Click any file to open it in the editor — no terminal needed to browse

> You may need to first fix permissions with `chown`/`chmod` (see next slide)  
> before VS Code can read files inside the task directory.

---

## Step 5c (alt) — Connect via Password / Plain SSH

If you created the user with a **password** instead of an SSH key:

```bash
ssh batch-explorer-user@<node-public-ip>
# enter password when prompted
```

Add to `~/.ssh/config` for VS Code compatibility:

```
Host schism-head
    HostName  <head-node-public-ip-address>
    Port      50000
    User      batch-explorer-user
```

VS Code Remote-SSH will prompt for the password on connect.

---

## Step 6 — Multiple Terminals: tmux

You only get one SSH session per login unless you use a multiplexer.  
**tmux** lets you run multiple panes/windows and keep sessions alive  
if your connection drops.

### Install tmux on the node (if not present)

```bash
sudo yum install -y tmux
```

### Basic tmux usage

```bash
tmux new -s schism          # start a named session
# Ctrl-b c                  # new window
# Ctrl-b "  or  Ctrl-b %    # split pane horizontal / vertical
# Ctrl-b d                  # detach (session stays running)
tmux attach -t schism       # re-attach after reconnecting
```

> Alternatively, just open **multiple terminal tabs** in VS Code  
> Remote-SSH — each tab is an independent SSH session.

---

## Step 6b — Fix Permissions on the Working Directory

Add `batch-explorer-user` to the `_azbatchgrp` group for shared access.
Create a `fix_batch_permissions.sh` with contents below

```bash
#!/bin/bash
set -e
WD_PATH="wd"   # run from inside the task directory

echo "Step 1: Adding batch-explorer-user to _azbatchgrp..."
sudo usermod -aG _azbatchgrp batch-explorer-user

echo "Step 2: Changing group ownership to _azbatchgrp..."
sudo chown -R :_azbatchgrp "$WD_PATH"

echo "Step 3: Granting group read-write permissions..."
sudo chmod -R g+rwX "$WD_PATH"

echo "Step 4: Setting setgid so new files inherit the group..."
sudo chmod -R g+s "$WD_PATH"

echo "Step 5: Verifying group memberships..."
groups _azbatch && groups batch-explorer-user
echo "All steps completed successfully!"
```

Run it from inside the task directory:

```bash
cd /mnt/batch/tasks/workitems/<job_id>/job-1/<task_id>
bash ~/fix_batch_permissions.sh
```

---

## Step 7 — Navigate to the Working Directory


After Step 6, you can edit files as `batch-explorer-user` 
Once permissions are fixed, navigate in:

```bash
cd /mnt/batch/tasks/workitems/<job_id>/job-1/<task_id>/wd
ls
```

You should see:
```
env_vars.sh            # full environment snapshot
coordination_command.sh
application_command.sh
```

> `env_vars.sh` is generated automatically during pool/task startup  
> by `generate_env_script.sh` and captures every `AZ_BATCH_*` and  
> `AZ_BATCH_APP_PACKAGE_*` variable along with module paths.

---

## Step 8 — Load the Environment (env_vars.sh)

Environment setup and SCHISM must run **as the `_azbatch` user** so that  
MPI host file setup and app package paths work correctly. Switch user first:

```bash
sudo su - _azbatch
```

This opens a new shell as `_azbatch`. Now navigate to the working directory:

```bash
cd /mnt/batch/tasks/workitems/<job_id>/job-1/<task_id>/wd
```

Then source `env_vars.sh`:

```bash
source env_vars.sh
```

This sets everything SCHISM and MPI need:
- `AZ_BATCH_APP_PACKAGE_schism_with_deps` → SCHISM binary path
- `AZ_BATCH_APP_PACKAGE_schimpy_with_deps` → Python env
- `AZ_BATCH_APP_PACKAGE_batch_setup` → `$SCHISM_SCRIPTS_HOME`
- `AZ_BATCH_HOST_LIST` → comma-separated list of all node IPs
- Module paths, `LD_LIBRARY_PATH`, `PATH`

---

## Step 8b — Load the Environment (application_command.sh)

As `_azbatch`, run only these essential lines (do **not** run the full script):

```bash
source /usr/share/Modules/init/bash
module load mpi/mvapich2
source $AZ_BATCH_APP_PACKAGE_schimpy_with_deps/bin/activate
source $AZ_BATCH_APP_PACKAGE_schism_with_deps/schism/setup_paths.sh
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup
export BAY_DELTA_SCHISM_HOME=$AZ_BATCH_APP_PACKAGE_baydeltaschism
ulimit -s unlimited
```

> Skip `coordination_command.sh` unless NFS or the MPI hostfile needs rebuilding.

> **`Host key verification failed.`** means you are not running as `_azbatch`.  
> Always `sudo su - _azbatch` before sourcing `env_vars.sh`.

---

## Step 9 — Install an Editor (if needed)

The node image may not include `nano` by default.

```bash
sudo yum install -y nano
```

Then edit `param.nml`:

```bash
nano param.nml
# Ctrl-O  save   |  Ctrl-X  exit
```

Or edit directly in **VS Code** if connected via Remote-SSH — no  
terminal editor needed, full syntax support.

---

## Step 10 — Run SCHISM Interactively

> Run these commands in the `_azbatch` terminal (`sudo su - _azbatch`)

### Navigate to the study directory

```bash
cd $SCHISM_STUDY_DIR
# or manually:
cd $AZ_BATCH_TASK_WORKING_DIR/simulations/<study_dir>
```

### Copy the mpirun command from `application_command.sh`

```bash
grep -A5 'mpirun' application_command.sh
```

### Run it

```bash
mpirun -n <num_cores> \
       -f hostfile \
       $AZ_BATCH_APP_PACKAGE_schism_with_deps/schism/bin/pschism_TVD-VL
```

> Output appears directly in your terminal. **Ctrl-C** cancels immediately.  
> **`Host key verification failed.`** during mpirun means you are not running  
> as `_azbatch`. Switch user (`sudo su - _azbatch`) and retry.

---

## Step 10b — Iterating on `param.nml`

```
Edit param.nml → mpirun → check outputs/ → repeat
```

```bash
# Edit a parameter in-place
sed -i 's/^\([[:space:]]*dt[[:space:]]*=\).*/\1 90.0/' param.nml

# Update ihot for a restart
bash $SCHISM_SCRIPTS_HOME/batch/update_param_for_restart.sh param.nml

# Check rnday
bash $SCHISM_SCRIPTS_HOME/batch/get_rndays_from_param_nml.sh param.nml
```

| Variable | Points to |
|---|---|
| `$SCHISM_SCRIPTS_HOME` | `$AZ_BATCH_APP_PACKAGE_batch_setup` |
| `$BAY_DELTA_SCHISM_HOME` | `$AZ_BATCH_APP_PACKAGE_baydeltaschism` |
| `$AZ_BATCH_APP_PACKAGE_schism_with_deps` | SCHISM binary + `setup_paths.sh` |

---

## Step 11 — Cleanup ⚠️

<div class="warn">

**Scale the pool to zero as soon as you are done. Every minute costs money.**

</div>

### Azure Portal

Pools → select pool → **Scale** → *Dedicated nodes* = **0** → Save

### Azure Batch Explorer

Jobs → select job → **Terminate** or **Delete**

### Azure CLI

```bash
az batch pool resize --pool-id <pool-id> \
    --target-dedicated-nodes 0 \
    --account-name <batch_account> \
    --account-endpoint https://<batch_account>.<region>.batch.azure.com
```

---

## Summary

```
1.   Keep pool alive        Fix pool size after allocation  (or dummy-wait)
1b.  Cost warning           ~$4/hr per H-series node — shut down asap
2.   Find head node         Batch Explorer: Jobs → Task → top-right IP
3.   Add remote user        Batch Explorer: Nodes → Add/Update User
4.   SSH key setup          ssh-keygen → paste pub key
4b.  SSH key (add user)     Portal / Batch Explorer / CLI
4c.  SSH config             ~/.ssh/config → HostName, User, IdentityFile
5.   Connect (VS Code)      Remote-SSH: Connect to Host → schism-head
5b.  Add folder             File → Add Folder to Workspace → /mnt/batch/tasks
5c.  Connect (password)     ssh batch-explorer-user@<ip>  (fallback)
6.   tmux (optional)        sudo yum install -y tmux → tmux new -s schism
6b.  Fix permissions        sudo chown/chmod on task working directory
7.   Navigate               cd /mnt/batch/tasks/.../wd
8.   Source env_vars.sh     source env_vars.sh
8b.  Source app_command     module load + activate + setup_paths.sh + ulimit
9.   Install nano           sudo yum install -y nano
10.  Run SCHISM             mpirun -n <N> -f hostfile pschism_TVD-VL
10b. Iterate param.nml      edit → run → check → repeat
11.  Cleanup                scale pool to 0 ← don't forget!
```
