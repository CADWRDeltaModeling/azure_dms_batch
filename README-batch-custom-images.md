# Using Custom Images with Azure Batch (Azure Compute Gallery + User Subscription Accounts)

This document explains how to run Azure Batch pools on a **custom image** — i.e. a VM image
that isn't in Batch's built-in supported-image catalog, most commonly because it's a
Marketplace image that carries a **purchase plan** (`RequiresPlan=true`), such as the
`almalinux-hpc` HPC images.

## Why this is needed

Azure Batch pools normally reference a Marketplace image directly with
`publisher`/`offer`/`sku`/`version` (see [pool.bicep](dmsbatch/templates/alma87_mvapich2_20241018/pool.bicep)).
That path only works for images/SKUs on Batch's internal supported-image allow-list. If you
reference a `publisher`/`offer`/`sku`/`version` combination that Batch doesn't recognize, ARM
rejects the pool outright with an error like:

```
The specified imageReference with publisher X offer Y sku Z is not supported.
```

This happens **regardless of pool allocation mode** (BatchService vs UserSubscription) — it's a
static allow-list check in the `Microsoft.Batch` resource provider, not a plan/licensing
restriction. There is no way to get an unsupported SKU string past this check.

The actual supported path for such images is to capture them as a **custom image** in an
**Azure Compute Gallery** (Shared Image Gallery), and reference the gallery image by resource ID
instead of publisher/offer/sku/version. Custom images that carry Marketplace purchase-plan info
additionally require the Batch account to be in **`UserSubscription`** pool allocation mode
(`BatchService`-mode accounts, the default, cannot allocate VMs from a plan-carrying custom
image at all).

Note: a plain Marketplace image reference (no plan, or a SKU that IS on Batch's allow-list, e.g.
`almalinux-hpc:8-hpc-gen2`) works fine on ordinary `BatchService`-mode accounts and does **not**
need any of this - only go down this path when the exact SKU/version you need is rejected by ARM.

## End-to-end workflow

1. Create a `UserSubscription`-mode Batch account (one-time per account).
2. Build the custom image from the Marketplace source and publish it to an Azure Compute Gallery.
3. Wire the gallery image into a `dmsbatch` pool template.
4. Configure the job YAML to authenticate against the new account (AAD, not Shared Key).
5. Copy the application packages your job needs onto the new account.

A worked example lives in this repo: account `schismbatchscus2`, gallery
`dwrmso_schism_scus_images`, image `schism_alma810_hpc_gen2`, template
[alma810_customimage_usersub](dmsbatch/templates/alma810_customimage_usersub), built from
`almalinux:almalinux-hpc:8_10-hpc-gen2:8.10.2024101801`.

---

## Step 1: Create a `UserSubscription`-mode Batch account

### 1a. One-time subscription prerequisites

These only need to be done once per Azure subscription (skip if already done):

```bash
# Register the resource provider (usually already registered)
az provider register --namespace Microsoft.Batch

# Get the first-party "Microsoft Azure Batch" service principal's object id
BATCH_SP_ID=$(az ad sp list --display-name "Microsoft Azure Batch" --query '[0].id' -o tsv)

# Let the Batch service create VMs/NICs/disks in your subscription on your behalf.
# Without this, every pool resize fails with an authorization error.
az role assignment create \
  --assignee-object-id "$BATCH_SP_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Batch Service Orchestration Role" \
  --scope /subscriptions/<SUBSCRIPTION_ID>
```

Also accept the Marketplace legal terms for the base image once per subscription:

```bash
az vm image terms accept --publisher almalinux --offer almalinux-hpc --plan 8_10-hpc-gen2
```

### 1b. Create a Key Vault (required for `UserSubscription` mode)

```bash
az keyvault create \
  --name <keyvault-name> \
  --resource-group <rg> \
  --location <region> \
  --enable-rbac-authorization true \
  --enabled-for-deployment true \
  --enabled-for-template-deployment true \
  --enabled-for-disk-encryption true

az role assignment create \
  --assignee-object-id "$BATCH_SP_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets Officer" \
  --scope $(az keyvault show --name <keyvault-name> --resource-group <rg> --query id -o tsv)
```

### 1c. Create the Batch account

Passing `--keyvault` automatically sets `poolAllocationMode` to `UserSubscription`:

```bash
az batch account create \
  --name <new-batch-account-name> \
  --resource-group <rg> \
  --location <region> \
  --keyvault $(az keyvault show --name <keyvault-name> --resource-group <rg> --query id -o tsv) \
  --storage-account $(az storage account show --name <existing-storage-account> --resource-group <rg> --query id -o tsv)
```

Verify: `az batch account show --name <acct> --resource-group <rg> --query poolAllocationMode`
should print `UserSubscription`.

### 1d. Quota

`UserSubscription`-mode pools draw on your **subscription's own Compute vCPU quota** for the VM
family (e.g. `standardHBrsv2Family` for `Standard_HB120rs_v2`), not the Batch account's own
quota. Check/request it:

```bash
az quota show --resource-name standardHBrsv2Family \
  --scope /subscriptions/<SUBSCRIPTION_ID>/providers/Microsoft.Compute/locations/<region>

az quota update --resource-name standardHBrsv2Family \
  --scope /subscriptions/<SUBSCRIPTION_ID>/providers/Microsoft.Compute/locations/<region> \
  --limit-object value=<N> --resource-type dedicated
```

**Gotcha:** the Quota RP requires an MFA-verified token. A plain `az login --use-device-code`
session gets `MFARequired` — submit the request via the Portal, or an interactive MFA login,
instead.

### 1e. Grant yourself Batch data-plane RBAC (do NOT skip this)

Being subscription **Owner does not grant Batch job/task submission rights**. Azure's built-in
Owner role has `actions: ["*"]` but **`dataActions: []` (empty)** — and Batch job/task
create/list/delete are `dataActions`. Without an explicit role, `dmsbatch schism submit-job`
will authenticate fine but fail on the first `create_job`/`create_task` call.

```bash
az role assignment create \
  --assignee-object-id <your-aad-object-id> \
  --assignee-principal-type User \
  --role "Azure Batch Job Submitter" \
  --scope $(az batch account show --name <acct> --resource-group <rg> --query id -o tsv)
```

("Azure Batch Job Submitter" grants exactly `Microsoft.Batch/batchAccounts/{jobs,jobSchedules}/*`
dataActions - least privilege for this purpose. "Azure Batch Data Contributor" also works but
additionally duplicates pool/application/certificate control-plane actions you likely already
have via Owner/Contributor.)

Validate end-to-end with a safe, read-only call before trying anything real:

```python
from azure.identity import DefaultAzureCredential
from azure.batch import BatchClient
client = BatchClient(endpoint="https://<acct>.<region>.batch.azure.com", credential=DefaultAzureCredential())
list(client.list_jobs())  # should succeed, not raise an auth error
```

---

## Step 2: Build the custom image into an Azure Compute Gallery

This uses Azure VM Image Builder (AIB) to capture a VM built from the Marketplace source into a
gallery image. See [schism_scripts/image/](schism_scripts/image/) for a full working example
(`image.sh`, `imageTemplateForAlma810Scus.json`, `aiRoleImageCreationTemplate.json`).

### 2a. Identity + RBAC for the image builder

```bash
az identity create -g <rg> -n <image-builder-identity> --location <region>
IDENTITY_ID=$(az identity show -g <rg> -n <image-builder-identity> --query principalId -o tsv)

# Custom role for Compute Gallery image read/write (see aiRoleImageCreationTemplate.json)
az role definition create --role-definition aiRoleImageCreationTemplate.json
az role assignment create --assignee-object-id "$IDENTITY_ID" --assignee-principal-type ServicePrincipal \
  --role "<your custom role name>" --scope /subscriptions/<sub>/resourceGroups/<rg>

# AIB also needs to provision a staging VM/NIC/disk - the narrow custom role above only covers
# gallery/image actions, so also grant Contributor on the resource group:
az role assignment create --assignee-object-id "$IDENTITY_ID" --assignee-principal-type ServicePrincipal \
  --role "Contributor" --scope /subscriptions/<sub>/resourceGroups/<rg>
```

### 2b. Create the gallery and image definition

```bash
az sig create -g <rg> --gallery-name <gallery-name> --location <region>

# If the source has a Marketplace purchase plan (RequiresPlan=true), the gallery image
# definition's plan info MUST exactly match the source image's plan info.
az sig image-definition create \
  -g <rg> --gallery-name <gallery-name> --gallery-image-definition <image-def-name> \
  --publisher <source-publisher> --offer <source-offer> --sku <source-sku> \
  --os-type Linux --os-state Generalized --hyper-v-generation V2 \
  --plan-name <source-sku> --plan-publisher <source-publisher> --plan-product <source-offer>
```

### 2c. Write the AIB template JSON

Key fields (see [imageTemplateForAlma810Scus.json](schism_scripts/image/imageTemplateForAlma810Scus.json)
for a complete example):

```json
{
  "type": "Microsoft.VirtualMachineImages",
  "apiVersion": "2020-02-14",
  "location": "<region>",
  "identity": {
    "type": "UserAssigned",
    "userAssignedIdentities": { "<identity-resource-id>": {} }
  },
  "properties": {
    "buildTimeoutInMinutes": 60,
    "vmProfile": { "vmSize": "Standard_D2s_v3", "osDiskSizeGB": 480 },
    "source": {
      "type": "PlatformImage",
      "publisher": "<source-publisher>",
      "offer": "<source-offer>",
      "sku": "<source-sku>",
      "version": "<pinned-version>",
      "planInfo": {
        "planName": "<source-sku>",
        "planProduct": "<source-offer>",
        "planPublisher": "<source-publisher>"
      }
    },
    "customize": [
      { "type": "Shell", "name": "customize", "inline": ["echo 'add your setup commands here'"] }
    ],
    "distribute": [
      {
        "type": "SharedImage",
        "galleryImageId": "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery-name>/images/<image-def-name>",
        "runOutputName": "<run-output-name>",
        "replicationRegions": ["<region-matching-your-batch-pool>"]
      }
    ]
  }
}
```

Notes:
- `customize` **cannot be empty** — AIB rejects `"customize": []` with "Customize list must not
  be empty." Use a no-op shell command if you only need a base-OS capture (e.g. to pre-install
  nothing and keep delivering software via Batch Application Packages as normal).
- `vmProfile.vmSize` is just the build machine — it doesn't need to match your target pool's VM
  size unless your customize scripts require specific hardware.
- `replicationRegions` must include the region your Batch pool will run in.
- Pin an exact `version` (don't use `"latest"`) so the captured image is reproducible.

### 2d. Deploy and run the build

```bash
az resource create \
  --resource-group <rg> \
  --properties @imageTemplate.json \
  --is-full-object \
  --resource-type Microsoft.VirtualMachineImages/imageTemplates \
  -n <image-template-name>

az resource invoke-action \
  --resource-group <rg> \
  --resource-type Microsoft.VirtualMachineImages/imageTemplates \
  -n <image-template-name> \
  --action Run
```

This is a long-running operation (15-45+ minutes even for a minimal capture). Poll status with:

```bash
az resource show -g <rg> --resource-type Microsoft.VirtualMachineImages/imageTemplates \
  -n <image-template-name> --query 'properties.lastRunStatus'
```

Once `runState` is `Succeeded`, get the resulting image version:

```bash
az sig image-version list -g <rg> --gallery-name <gallery-name> --gallery-image-definition <image-def-name> -o table
```

---

## Step 3: Wire the gallery image into a `dmsbatch` pool template

Create a new template folder (see [alma810_customimage_usersub](dmsbatch/templates/alma810_customimage_usersub)
for a full example, cloned from an existing MPI template). The only real change needed is
`pool.bicep`'s `imageReference` default — Batch's ARM schema accepts either
`{publisher, offer, sku, version}` **or** `{id}` for a gallery image, mutually exclusive:

```bicep
param imageReference object = {
  id: '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery-name>/images/<image-def-name>/versions/<version>'
}
param nodeAgentSKUId string = 'batch.node.el 8'   // must match the base OS, same as a normal pool
```

Everything else (mount config, app packages, start task) stays the same as any other template.

---

## Step 4: Job YAML changes for a `UserSubscription` account

Your job config just needs to point at the new account and use AAD auth (Shared Key is rejected
outright on accounts whose `allowedAuthenticationModes` excludes it — check with
`az batch account show --name <acct> --query allowedAuthenticationModes`):

```yaml
batch_account_name: <new-batch-account-name>
auth_mode: aad   # skip fetching a shared key entirely; uses azure.identity.DefaultAzureCredential
template_name: <your-new-template-folder>
```

`auth_mode` defaults to `shared_key` for full backward compatibility with every existing
template/account — set it to `aad` only for accounts that need it. It's simplest to default it
in the template's own `default_config.yml` (as done for `alma810_customimage_usersub`) so every
job using that template gets it automatically without per-job boilerplate.

---

## Step 5: Copy application packages to the new account

Application packages are **not** shared between Batch accounts — each account has its own
independent set. If your job's `app_pkgs` reference packages that only exist on another account,
you'll need to copy them over. Azure Batch's management API only exposes a package's direct
download URL (`storageUrl`) for ~48 hours after upload; after that there's no supported way to
read an already-activated package back through the Batch API.

The good news: the package blob is still retained indefinitely in the Batch account's **linked
auto-storage account**, in a system-managed container named `app-{name-with-hyphens}-{hash}`,
blob-named as the raw version string. [app-packages/batch_app_package_and_upload.sh](app-packages/batch_app_package_and_upload.sh)
has ready-made functions for this:

```bash
source app-packages/batch_app_package_and_upload.sh

# Download one package's default version from the source account
download_batch_app_package <app_name> <source_batch_account> <source_rg> default /tmp/packages

# Or download every app's default version at once
download_all_default_packages <source_batch_account> <source_rg> /tmp/packages

# Then register+activate+set-default on the target account
package_and_upload_app <app_name> <version> /tmp/packages/<app_name>_<version>.zip <target_batch_account> <target_rg>
```

**Gotchas:**
- An app can end up with **multiple** hash-suffixed containers in the auto-storage account
  (e.g. from a past re-registration), with its version history split across them —
  `download_batch_app_package` checks all matching containers for the target blob, not just the
  first one found.
- **Never chain multiple large (>100MB) `az batch application package create` uploads together
  in one shell invocation.** A multi-command chain can silently truncate mid-upload, leaving the
  package stuck in `state: Pending` with `ApplicationPackageBlobNotFound` on activation. Upload
  one package at a time, and check `az batch application package show ... --query state` before
  activating if anything seems off. If a package does end up stuck, delete the broken version
  (`az batch application package delete`) and re-upload it on its own.

---

## Quick troubleshooting reference

| Symptom | Cause | Fix |
|---|---|---|
| `The specified imageReference with publisher X offer Y sku Z is not supported` | SKU not in Batch's ARM allow-list (any pool mode) | Use Azure Compute Gallery custom image (Step 2-3) |
| `AllocationFailed` / "The specified image is not found" | Wrong/nonexistent sku+version combination | Double check `az vm image show`/`az vm image list` for the exact valid combo |
| Pool creation works but real node allocation fails on quota | `UserSubscription` mode uses subscription Compute quota, not Batch-account quota | Request quota for the VM family (Step 1d) |
| `dmsbatch` job submission fails immediately with an auth error | Account's `allowedAuthenticationModes` excludes SharedKey | Set `auth_mode: aad` in the job YAML (Step 4) |
| AAD auth works but `create_job`/`create_task` still fails | Owner/Contributor roles don't include Batch `dataActions` | Grant "Azure Batch Job Submitter" scoped to the account (Step 1e) |
| Job fails because an application package isn't found | Packages aren't shared between Batch accounts | Copy packages over (Step 5) |
