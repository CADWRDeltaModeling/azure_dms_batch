#!/usr/bin/bash

# Check if the Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI not found. Please install it first."
    exit 1
fi

# Check if logged in to Azure
az account show &> /dev/null
if [ $? -ne 0 ]; then
    echo "You are not logged into Azure. Please login using 'az login' first."
    exit 1
fi

# Get today's date
today=$(date +%Y-%m-%d)
output_file="blob_inventory_$today.csv"

# Resume support:
#   - An existing inventory csv can be passed explicitly as the first argument
#     (e.g. the file left behind by an interrupted run).
#   - If no argument is given, but today's default output file already exists,
#     that file is treated as the interrupted run and reused automatically.
# In either case, entries (StorageAccount,Container pairs) already present in
# the resume file are skipped, and new entries are appended to it.
resume_file="$1"

if [ -z "$resume_file" ] && [ -f "$output_file" ]; then
    resume_file="$output_file"
fi

declare -A processed

if [ -n "$resume_file" ] && [ -f "$resume_file" ]; then
    echo "Resuming from existing inventory file: $resume_file"
    output_file="$resume_file"

    while IFS=',' read -r sa ctr _rest; do
        [ "$sa" = "StorageAccount" ] && continue
        [ -z "$sa" ] && continue
        processed["$sa|$ctr"]=1
    done < "$resume_file"

    echo "Found ${#processed[@]} already-processed storage/container entries; they will be skipped."
else
    # Create output file and add header
    echo "StorageAccount,Container,Tier,Size_MB,BlobCount" > "$output_file"
fi

# Get all storage accounts in the subscription
echo "Retrieving all storage accounts in the subscription..."
storage_accounts=$(az storage account list --query "[].name" -o tsv)

if [ -z "$storage_accounts" ]; then
    echo "No storage accounts found in the current subscription."
    exit 0
fi

# Loop through each storage account
for storage in $storage_accounts; do
    echo "Processing storage account: $storage"

    # Get the storage account key using a more secure method
    key=$(az storage account keys list --account-name $storage --query "[0].value" --output tsv)

    # List containers with error handling
    containers=$(az storage container list --account-name $storage --account-key $key --output tsv --query "[].name" 2>/dev/null)

    if [ -z "$containers" ]; then
        if [ -n "${processed["$storage|No containers"]:-}" ]; then
            echo "  Skipping $storage (already recorded as having no containers)"
        else
            echo "$storage,No containers,N/A,0,0" >> "$output_file"
        fi
        continue
    fi

    # Process each container
    for container in $containers; do
        if [ -n "${processed["$storage|$container"]:-}" ]; then
            echo "  Skipping already processed container: $container"
            continue
        fi

        echo "  Processing container: $container"
        # Fetch size (bytes) and blob tier for every blob in the container
        blob_data=$(az storage blob list --container-name $container --account-key $key --account-name $storage \
            --num-results '*' \
            --query "[*].[properties.contentLength, properties.blobTier]" --output tsv 2>/dev/null)

        if [ -z "$blob_data" ]; then
            echo "$storage,$container,N/A,0,0" >> "$output_file"
            continue
        fi

        # Emit one row per tier: StorageAccount,Container,Tier,Size_MB,BlobCount
        echo "$blob_data" | awk -v sa="$storage" -v ctr="$container" '
            {
                size = $1
                tier = ($2 != "" && $2 != "None" && $2 != "null") ? $2 : "Unknown"
                sum[tier]  += size
                count[tier]++
            }
            END {
                for (tier in sum)
                    printf "%s,%s,%s,%.2f,%d\n", sa, ctr, tier, sum[tier]/1024/1024, count[tier]
            }
        ' >> "$output_file"
    done
done

echo "Inventory complete! Results saved to $output_file"
