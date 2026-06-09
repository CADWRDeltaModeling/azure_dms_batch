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

## Step 1 — Cost Warning ⚠️

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

1. Open **Batch Explorer** → select your Batch account
2. Navigate **Pools** → select your pool → **Nodes** tab
3. Find the node whose state is **Running** — the **IP address** is shown directly in the list
4. Note the IP — you will use it to SSH in

> **Which node is the head node?**  
> The head node is the one where `AZ_BATCH_IS_CURRENT_NODE_MASTER = true`.  
> Confirm by clicking the node → **Files** → open `stdout.txt` — it prints:  
> `This is the master node. <node-id>, master node ip is <ip>`

*Alternative — Azure Portal:* Batch Account → Pools → pool → Nodes → click node → copy Public IP.  
*Alternative — CLI:* `az batch node list --pool-id <pool>` and look for the running task node.

---

## Step 3 — Create a Remote User (Batch Explorer)

### Recommended: Azure Batch Explorer

1. **Pools** → select pool → **Nodes** → right-click the head node
2. Click **Connect** (or **Add User**)
3. Fill in:
   - **Username** — e.g. `debuguser`
   - **Password** or **SSH public key** — paste contents of `~/.ssh/schism_batch.pub` *(see SSH key slides)*
   - **Admin** — ✅ enable (required to access `/mnt/batch/`)
   - **Expiry** — default 24 h; extend if needed
4. Click **Create**

> Repeat for any worker nodes if you need to SSH into them for debugging.

*Alternative — Azure Portal:* Batch Account → Pools → pool → Nodes → select node → **Add User** → same fields.  
*Alternative — CLI:* `az batch node user create --pool-id <pool> --node-id <node> --name debuguser --ssh-public-key "$(cat ~/.ssh/schism_batch.pub)" --is-admin true`

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

## Step 4 — SSH Key Setup in Azure (continued)

### 3. Add user with the SSH public key

**Azure Portal** — when adding the user, paste the public key into  
the **SSH public key** field instead of setting a password.

**Azure Batch Explorer** — same **Add User** dialog, paste the key.

**Azure CLI:**
```bash
az batch node user create \
  --pool-id <pool-id> \
  --node-id <node-id> \
  --name debuguser \
  --ssh-public-key "$(cat ~/.ssh/schism_batch.pub)" \
  --is-admin true \
  --account-name <batch_account> \
  --account-endpoint https://<batch_account>.<region>.batch.azure.com
```

---

## Step 4 — SSH Key Setup in Azure (continued)

### 4. Configure `~/.ssh/config` on your local machine

```
Host schism-head
    HostName      <head-node-public-ip-address>
    Port          50000
    User          debuguser
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

## Step 5 (alt) — Connect via Password / Plain SSH

If you created the user with a **password** instead of an SSH key:

```bash
ssh debuguser@<node-public-ip>
# enter password when prompted
```

Add to `~/.ssh/config` for VS Code compatibility:

```
Host schism-head
    HostName  <head-node-public-ip-address>
    Port      50000
    User      debuguser
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

## Step 7 — Navigate to the Working Directory

Once on the node, find the task working directory:

```bash
cd /mnt/batch/tasks/workitems/<job_id>/<task_id>/wd
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

## Step 8 — Load the Environment

### Source `env_vars.sh` — always do this first

```bash
source env_vars.sh
```

This sets everything SCHISM and MPI need:
- `AZ_BATCH_APP_PACKAGE_schism_with_deps` → SCHISM binary path
- `AZ_BATCH_APP_PACKAGE_schimpy_with_deps` → Python env
- `AZ_BATCH_APP_PACKAGE_batch_setup` → `$SCHISM_SCRIPTS_HOME`
- `AZ_BATCH_HOST_LIST` → comma-separated list of all node IPs
- Module paths, `LD_LIBRARY_PATH`, `PATH`

### Extract only the setup lines from `application_command.sh`

Do **not** run `application_command.sh` in full — it will re-copy data  
and re-launch the MPI job. Copy and run only these essential lines:

```bash
# 1. Initialize the module system
source /usr/share/Modules/init/bash

# 2. Load MPI (match your template — mvapich2 or hpcx)
module load mpi/mvapich2

# 3. Activate the Python environment (schimpy etc.)
source $AZ_BATCH_APP_PACKAGE_schimpy_with_deps/bin/activate

# 4. Load SCHISM shared libraries and add binary to PATH
source $AZ_BATCH_APP_PACKAGE_schism_with_deps/schism/setup_paths.sh

# 5. Set helper script paths
export SCHISM_SCRIPTS_HOME=$AZ_BATCH_APP_PACKAGE_batch_setup
export BAY_DELTA_SCHISM_HOME=$AZ_BATCH_APP_PACKAGE_baydeltaschism

# 6. Remove stack size limit (required for SCHISM)
ulimit -s unlimited
```

> `coordination_command.sh` — only needed if the NFS mount or MPI  
> hostfile needs to be rebuilt from scratch. Skip it otherwise.

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
> You can redirect to a file: `mpirun ... 2>&1 | tee run.log`

---

## Iterating on `param.nml`

```
Edit param.nml  →  mpirun  →  check outputs/  →  repeat
```

### Useful one-liners

```bash
# Edit a specific parameter in-place
sed -i 's/^\([[:space:]]*dt[[:space:]]*=\).*/\1 90.0/' param.nml

# Update ihot flag for a restart run
bash $SCHISM_SCRIPTS_HOME/batch/update_param_for_restart.sh param.nml

# Check current rnday value
bash $SCHISM_SCRIPTS_HOME/batch/get_rndays_from_param_nml.sh param.nml
```

### Key paths (set by `env_vars.sh`)

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
1.  Keep pool alive     Fix pool size after allocation  (or dummy-wait)
2.  Find head node      Portal / Batch Explorer → Nodes → IP
3.  Add remote user     Portal / CLI → Add User (admin, SSH key)
4.  SSH key setup       ssh-keygen → paste pub key → ~/.ssh/config
5.  Connect             VS Code Remote-SSH  or  ssh schism-head
6.  tmux (optional)     sudo yum install -y tmux  →  tmux new -s schism
7.  Navigate            cd /mnt/batch/tasks/.../wd
8.  Source env          source env_vars.sh
9.  Setup libs          source .../setup_paths.sh  (from app_command)
10. Install nano        sudo yum install -y nano
11. Edit param.nml      nano  or  VS Code editor
12. Run SCHISM          mpirun -n <N> -f hostfile pschism_TVD-VL
13. Iterate             edit → run → check → repeat
14. Cleanup             scale pool to 0  ← don't forget!
```
