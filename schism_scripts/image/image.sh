#!/bin/bash

# Get the user identity URI that's needed for the template
function get_identity_client_id {
    local sigResourceGroup="$1"
    local identityName="$2"

    # Get the identity ID
    local imgBuilderCliId=$(az identity show -g "$sigResourceGroup" -n "$identityName" --query clientId -o tsv)
    echo "$imgBuilderCliId"
}

# Get the user identity URI that's needed for the template
function get_image_builderid {
    local subscriptionID="$1"
    local sigResourceGroup="$2"
    local identityName="$3"

    # Get the user identity URI that's needed for the template
    local imgBuilderId="/subscriptions/$subscriptionID/resourcegroups/$sigResourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$identityName"

    echo "$imgBuilderId"
}

# create a user identity
function create_user_identity {
    local sigResourceGroup="$1"
    local identityName="$2"
    az identity create -g $sigResourceGroup -n $identityName
}

function assign_image_builder_role {
    local subscriptionID="$1"
    local sigResourceGroup="$2"
    local identityName="$3"

    local imgBuilderCliId=$(get_identity_client_id $sigResourceGroup $identityName)

    # Get the user identity URI that's needed for the template
    local imgBuilderId=$(get_image_builderid $subscriptionID $sigResourceGroup $identityName)

    # Download an Azure role-definition template, and update the template with the parameters that were specified earlier
    #curl https://raw.githubusercontent.com/Azure/azvmimagebuilder/master/solutions/12_Creating_AIB_Security_Roles/aibRoleImageCreation.json -o aibRoleImageCreationTemplate.json
    local imageRoleDefName="Schism Image Builder Role Def" # $(date +'%s')

    # Update the definition
    cp aibRoleImageCreationTemplate.json aibRoleImageCreation.json
    sed -i -e "s/<subscriptionID>/$subscriptionID/g" aibRoleImageCreation.json
    sed -i -e "s/<rgName>/$sigResourceGroup/g" aibRoleImageCreation.json
    sed -i -e "s/Azure Image Builder Service Image Creation Role/$imageRoleDefName/g" aibRoleImageCreation.json

    # Create role definitions
    az role definition create --role-definition ./aibRoleImageCreation.json

    # Grant a role definition to the user-assigned identity
    az role assignment create \
        --assignee $imgBuilderCliId \
        --role "$imageRoleDefName" \
        --scope /subscriptions/$subscriptionID/resourceGroups/$sigResourceGroup
    
    rm aibRoleImageCreation.json
}


function add_role_for_storage_account {
    local subscriptionID="$1"
    local strResourceGroup="$2"
    local imgBuilderCliId="$3"
    local scriptStorageAcc="$4"
    local scriptStorageAccContainer="$5"
    az role assignment create \
    --assignee $imgBuilderCliId \
    --role "Storage Blob Data Reader" \
    --scope /subscriptions/$subscriptionID/resourceGroups/$strResourceGroup/providers/Microsoft.Storage/storageAccounts/$scriptStorageAcc/blobServices/default/containers/$scriptStorageAccContainer
}

function create_image_def_and_gallery {
    local sigResourceGroup="$1"
    local sigName="$2"
    local imageDefName="$3"
    local offer="$4" # centos7
    local sku="$5" # 5_10_1

    az sig create -g $sigResourceGroup --gallery-name $sigName
    az sig image-definition create -g $sigResourceGroup --gallery-name $sigName --gallery-image-definition $imageDefName \
    --publisher DWRMSO --offer $offer --sku $sku --os-type Linux --hyper-v-generation V2
}


function show_image_list {
    local publisher="$1" # e.g. OpenLogic
    az vm image list --publisher $publisher --output table --all
}


function create_image_version {
    #create_image_version $subscriptionID $sigResourceGroup $imageDefName $sigName $location $additionalregion $scriptUrl $runOutputName $imageName $imgBuilderId $imageTemplateFile
    local subscriptionID="$1"
    local sigResourceGroup="$2"
    local imageDefName="$3"
    local sigName="$4"
    local location="$5"
    local additionalregion="$6"
    local runOutputName="$7"
    local imageName="$8"
    local imgBuilderId="$9"
    local imageTemplateFile="${10}" # e.g. imageTemplateForCentos7.json
    # Create a template for the image version
    cp $imageTemplateFile imageTemplateFilled.json
    sed -i -e "s/<subscriptionID>/$subscriptionID/g" imageTemplateFilled.json
    sed -i -e "s/<rgName>/$sigResourceGroup/g" imageTemplateFilled.json
    sed -i -e "s/<imageDefName>/$imageDefName/g" imageTemplateFilled.json
    sed -i -e "s/<sharedImageGalName>/$sigName/g" imageTemplateFilled.json
    sed -i -e "s/<region1>/$location/g" imageTemplateFilled.json
    sed -i -e "s/<region2>/$additionalregion/g" imageTemplateFilled.json
    sed -i -e "s/<runOutputName>/$runOutputName/g" imageTemplateFilled.json
    sed -i -e "s%<imgBuilderId>%$imgBuilderId%g" imageTemplateFilled.json

    az resource create \
    --resource-group $sigResourceGroup \
    --properties @imageTemplateFilled.json \
    --is-full-object \
    --resource-type Microsoft.VirtualMachineImages/imageTemplates \
    -n $imageName

    az resource invoke-action \
     --resource-group $sigResourceGroup \
     --resource-type  Microsoft.VirtualMachineImages/imageTemplates \
     -n $imageName \
     --action Run

    rm imageTemplateFilled.json
}


function delete_image_builder_template {
    local sigResourceGroup="$1"
    local imageName="$2"
    az resource delete --resource-group $sigResourceGroup -n $imageName --resource-type Microsoft.VirtualMachineImages/imageTemplates --verbose
}

function create_image_for_centos7 {
    subscriptionID=$(az account show --query id -o tsv)
    # Create user-assigned identity for VM Image Builder to access the storage account where the script is stored
    identityName="schism_image_builder_role" # $(date +'%s')
    # Resource group name - dwrbdo_schism_rg
    sigResourceGroup=dwrbdo_schism_rg
    # Name of the Azure Compute Gallery - myGallery in this example
    sigName=dwrmso_schism_images
    # Datacenter location - West US
    location=eastus
    # Additional region to replicate the image to
    additionalregion=westus2
    # Reference name in the image distribution metadata
    runOutputName=schism
    imgBuilderId=$(get_image_builderid "$subscriptionID" "$sigResourceGroup" "$identityName")
    ####
    #show_image_list OpenLogic
    #x64             CentOS-HPC                 OpenLogic    7_9-gen2         OpenLogic:CentOS-HPC:7_9-gen2:7.9.2022040101                        7.9.2022040101
    ####
    # Name of the image definition to be created - myImageDef in this example
    imageDefName=schism_5.10.1
    # name of the image builder template
    imageName='imageForCentos7HBv2'
    imageTemplateFile="imageTemplateForCentos7.json"
    #create_image_def_and_gallery "$sigResourceGroup" "$sigName" $imageDefName "centos7" "5_10_1"
    #delete_image_builder_template "$sigResourceGroup" "$imageName" # if you want to delete the image builder template
    create_image_version "$subscriptionID" "$sigResourceGroup" "$imageDefName" "$sigName" "$location" "$additionalregion" "$runOutputName" "$imageName" "$imgBuilderId" "$imageTemplateFile"
}

function create_image_for_alma8 {
    subscriptionID=$(az account show --query id -o tsv)
    identityName="schism_image_builder_role" # $(date +'%s')
    sigResourceGroup=dwrbdo_schism_rg
    sigName=dwrmso_schism_images
    location=eastus
    additionalregion=westus2
    runOutputName=schism
    imgBuilderId=$(get_image_builderid "$subscriptionID" "$sigResourceGroup" "$identityName")
    ####
    #show_image_list almalinux
    #x64             almalinux-hpc  almalinux                           8_7-hpc-gen2  almalinux:almalinux-hpc:8_7-hpc-gen2:8.7.2023060101              8.7.2023060101
    ####
    # Name of the image definition to be created - myImageDef in this example
    imageDefName=schism_alma8_5.10.1
    imageName='imageForAlma87HBv2'
    imageTemplateFile="imageTemplateForAlma8.json"
    #create_image_def_and_gallery "$sigResourceGroup" "$sigName" $imageDefName "centos7" "5_10_1"
    #delete_image_builder_template "$sigResourceGroup" "$imageName" # if you want to delete the image builder template
    create_image_version "$subscriptionID" "$sigResourceGroup" "$imageDefName" "$sigName" "$location" "$additionalregion" "$runOutputName" "$imageName" "$imgBuilderId" "$imageTemplateFile"
}