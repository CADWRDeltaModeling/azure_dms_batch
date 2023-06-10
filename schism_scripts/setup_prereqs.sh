# Fill these in with your own values
group_name="fill in resource group name here"
location="fill in location here, e.g. eastus"
storage_account_name="fill in storage account name here, e.g. mystorage1"
batch_account_name="fill in batch account name here, e.g. mybatch1"
# End of user input
az group create --name $group_name --location $location
az storage account create --name $storage_account_name --resource-group $group_name --location $location --sku Standard_LRS
az batch account create --location $location --name $batch_account_name --resource-group $group_name --storage-account $storage_account_name
