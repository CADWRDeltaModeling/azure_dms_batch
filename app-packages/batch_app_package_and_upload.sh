#!/bin/env bash

########################################################################################
# Instruction
# 1. Make sure the hard-wired paths are correct (those that follow "zip -r")
# 2. Run the following command to make the script accessible:
#    source batch_app_package_and_upload.sh
# 3. From the "Call the function" section, locate the lines of command you want to run.
#    Comment them out, copy, and paste the functions into the terminal.
########################################################################################
package_and_upload_telegraf() {
    # Make sure that the telegraf.conf file in the telegraf directory has the instrumentation key specified or it will not be able to send data to the app insights
    telegraf_dir=$1
    batch_name=$2
    resource_group_name=$3

    pushd $telegraf_dir
    # todays date in 2024.06.11 format
    version=$(date +"%Y.%m.%d")
    package_file="telegraf_${version}.zip"
    zip -r "../${package_file}" *
    popd
    module load azure_cli
    az batch application package create --application-name telegraf --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${version}"
    az batch application set --application-name telegraf --default-version "${version}" --name ${batch_name} --resource-group ${resource_group_name}    
}

package_and_upload_bdschism() {
    # if only 2 arguments are provided, the function will clone the repository
    if [ $# -eq 2 ]; then
        bdschism_dir="/tmp/BayDeltaSCHISM"
        batch_name=$1
        resource_group_name=$2
    else
        bdschism_dir=$1
        batch_name=$2
        resource_group_name=$3
    fi
    # todays date in 2024.06.11 format
    today=$(date +"%Y.%m.%d")
    package_file="BayDeltaSCHISM_${today}.zip"
    this_dir=$(pwd)

    # if bdschism_dir is not a directory, clone the repository
    if [ $# -eq 2 ]; then
        pushd /tmp
        rm -rf BayDeltaSCHISM # clean up the directory if it exists
        echo "Cloning the BayDeltaSCHISM repository from github"
        git clone https://github.com/CADWRDeltaModeling/BayDeltaSCHISM
        pushd ./BayDeltaSCHISM
        bdschism_dir=$(pwd)
    else
        pushd $bdschism_dir
    fi

    zip -r "${package_file}" *
    mv "${package_file}" $this_dir

    popd
    popd
    module load azure_cli
    az batch application package create --application-name BayDeltaSCHISM --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${today}"
    az batch application set --application-name BayDeltaSCHISM --default-version "${today}" --name ${batch_name} --resource-group ${resource_group_name}
}

package_and_upload_app() {
    app_name=$1
    version=$2
    package_file=$3
    batch_name=$4
    resource_group_name=$5

    module load azure_cli
    echo "Creating application package ${app_name} with version ${version} using ${package_file} for ${batch_name} in ${resource_group_name}"
    az batch application package create --application-name ${app_name} --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${version}"
    echo "Making ${version} the default version for ${app_name} for ${batch_name} in ${resource_group_name}"
    az batch application set --application-name ${app_name} --default-version "${version}" --name ${batch_name} --resource-group ${resource_group_name}
}

package_and_upload_batch_setup(){
    batch_setup_dir=$1
    batch_name=$2
    resource_group_name=$3

    version="alma8.7"
    package_file="batch_setup_${version}.zip"
    this_dir=$(pwd)
    pushd $batch_setup_dir
    zip -r "${package_file}" batch
    mv "${package_file}" $this_dir
    popd
    module load azure_cli
    az batch application package create --application-name batch_setup --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${version}"
    az batch application set --application-name batch_setup --default-version "${version}" --name ${batch_name} --resource-group ${resource_group_name}
}

package_and_upload_schimpy(){
    batch_name=$1
    resource_group_name=$2
    app_name="schimpy_with_deps"
    # todays date in 2024.06.11 format
    today=$(date +"%Y.%m.%d")
    version=${today}
    rm -rf /tmp/schimpy_with_deps_${version}
    mkdir -p /tmp/schimpy_with_deps_${version}
    pushd /tmp/schimpy_with_deps_${version}
    wget https://raw.githubusercontent.com/CADWRDeltaModeling/BayDeltaSCHISM/master/schism_env.linux.yml
    conda env remove -n schimpy_${version} -y || true
    conda env create -f schism_env.linux.yml -n schimpy_${version}
    conda activate pack
    conda pack -n schimpy_${version} -o schimpy.tar.gz
    zip -r schimpy_${version}.zip schimpy.tar.gz
    conda deactivate
    conda env remove -n schimpy_${version} -y
    package_file="schimpy_${version}.zip"

    module load azure_cli
    az batch application package create --application-name "${app_name}" --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${version}"
    az batch application set --application-name "${app_name}" --default-version "${version}" --name ${batch_name} --resource-group ${resource_group_name}
    popd
}

package_and_upload_suxarray_with_deps(){
    batch_name=$1
    resource_group_name=$2
    app_name="suxarray_with_deps"
    # todays date in 2024.06.11 format
    today=$(date +"%Y.%m.%d")
    version=${today}
    rm -rf /tmp/suxarray_with_deps_${version}
    mkdir -p /tmp/suxarray_with_deps_${version}
    pushd /tmp/suxarray_with_deps_${version}
    conda env remove -n suxarray_${version} -y || true
    conda create -n suxarray_${version} -y -c conda-forge -c cadwr-dms python=3.11 dask netcdf4 h5netcdf numba scipy scikit-learn matplotlib pyarrow requests spatialpandas cartopy datashader antimeridian shapely geoviews pyogrio pandas=2.0.3 xarray=2024.7.0 pyproj schimpy # these are pinned dependencies for suxarray branch v2024.09.0
    conda activate suxarray_${version}
    pip install --use-pep517 git+https://github.com/cadwrdeltamodeling/suxarray.git@v2024.09.0
    conda activate pack
    conda pack -n suxarray_${version} -o suxarray.tar.gz
    zip -r suxarray_${version}.zip suxarray.tar.gz
    conda deactivate
    conda deactivate
    conda deactivate
    conda env remove -n suxarray_${version} -y
    package_file="suxarray_${version}.zip"

    module load azure_cli
    az batch application package create --application-name "${app_name}" --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${version}"
    az batch application set --application-name "${app_name}" --default-version "${version}" --name ${batch_name} --resource-group ${resource_group_name}
    popd
}

package_and_upload_suxarray(){
    batch_name=$1
    resource_group_name=$2
    app_name="suxarray"
    # todays date in 2024.06.11 format
    today=$(date +"%Y.%m.%d")
    version=${today}
    rm -rf /tmp/${app_name}_${version}
    mkdir -p /tmp/${app_name}_${version}
    pushd /tmp/${app_name}_${version}
    conda env remove -n ${app_name} -y || true
    conda create -n ${app_name} -y -c conda-forge python=3.11 pandas xarray dask netcdf4 h5netcdf numba scipy scikit-learn matplotlib pyarrow requests spatialpandas cartopy datashader antimeridian shapely geoviews pyogrio
    conda activate pack
    conda pack -n ${app_name} -o ${app_name}.tar.gz
    zip -r ${app_name}_${version}.zip ${app_name}.tar.gz
    conda deactivate
    conda env remove -n ${app_name} -y
    package_file="${app_name}_${version}.zip"

    module load azure_cli
    az batch application package create --application-name "${app_name}" --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${version}"
    az batch application set --application-name "${app_name}" --default-version "${version}" --name ${batch_name} --resource-group ${resource_group_name}
    popd
}

download_batch_app_package() {
    # Downloads a Batch application package zip from an existing batch account.
    # If version is omitted or set to "default", the account's default version is used.
    # Usage:
    #   download_batch_app_package <app_name> <batch_name> <resource_group> [version] [output_dir]
    #
    # Examples:
    #   download_batch_app_package telegraf schismbatch dwrbdo_schism_rg
    #   download_batch_app_package telegraf schismbatch dwrbdo_schism_rg default /tmp/packages
    #   download_batch_app_package schism_with_deps schismbatch dwrbdo_schism_rg 5.11.1_alma8.7hpc_hpcx
    local app_name=$1
    local batch_name=$2
    local resource_group=$3
    local version=${4:-default}
    local output_dir=${5:-.}

    # Resolve "default" to the actual default version string
    if [[ "$version" == "default" ]]; then
        version=$(az batch application show \
            --application-name "${app_name}" \
            --name "${batch_name}" \
            --resource-group "${resource_group}" \
            --query defaultVersion \
            --output tsv)
        if [[ -z "$version" ]]; then
            echo "ERROR: No default version set for application '${app_name}' in batch account '${batch_name}'." >&2
            return 1
        fi
        echo "Resolved default version: ${version}"
    fi

    # Get the SAS URL for the package blob
    local storage_url
    storage_url=$(az batch application package show \
        --application-name "${app_name}" \
        --name "${batch_name}" \
        --resource-group "${resource_group}" \
        --version-name "${version}" \
        --query storageUrl \
        --output tsv)

    if [[ -z "$storage_url" ]]; then
        echo "ERROR: Could not retrieve storage URL for ${app_name} v${version}." >&2
        return 1
    fi

    mkdir -p "${output_dir}"
    local output_file="${output_dir}/${app_name}_${version}.zip"
    echo "Downloading ${app_name} v${version} -> ${output_file}"

    # Prefer azcopy if available (faster for large packages), fall back to wget
    if command -v azcopy &>/dev/null; then
        azcopy copy "${storage_url}" "${output_file}"
    else
        wget -q --show-progress -O "${output_file}" "${storage_url}"
    fi

    echo "Done: ${output_file}"
}

download_all_default_packages() {
    # Downloads the default version of every application in a batch account.
    # Usage:
    #   download_all_default_packages <batch_name> <resource_group> [output_dir]
    local batch_name=$1
    local resource_group=$2
    local output_dir=${3:-.}

    local app_names
    app_names=$(az batch application list \
        --name "${batch_name}" \
        --resource-group "${resource_group}" \
        --query "[].name" \
        --output tsv)

    if [[ -z "$app_names" ]]; then
        echo "No applications found in batch account '${batch_name}'." >&2
        return 1
    fi

    echo "Applications found in '${batch_name}':"
    while IFS= read -r app_name; do
        echo "  - ${app_name}"
    done < <(echo "$app_names")
    echo ""

    while IFS= read -r app_name <&3; do
        echo "--- Downloading ${app_name} ---"
        ( download_batch_app_package "${app_name}" "${batch_name}" "${resource_group}" default "${output_dir}" ) \
            || echo "WARNING: skipping ${app_name} (no default version or error)"
    done 3< <(echo "$app_names")
}

generate_upload_commands() {
    # Generates package_and_upload_app commands for all default-version packages in a
    # source batch account, ready to be run against a target batch account.
    # Usage:
    #   generate_upload_commands <src_batch> <src_resource_group> <dst_batch> <dst_resource_group> [package_dir]
    #
    # Examples:
    #   generate_upload_commands schismbatch dwrbdo_schism_rg newbatch new_rg /tmp/packages
    #   generate_upload_commands schismbatch dwrbdo_schism_rg newbatch new_rg   # uses current dir
    local src_batch=$1
    local src_rg=$2
    local dst_batch=$3
    local dst_rg=$4
    local package_dir=${5:-.}

    local app_data
    app_data=$(az batch application list \
        --name "${src_batch}" \
        --resource-group "${src_rg}" \
        --query "[].[name, defaultVersion]" \
        --output tsv)

    if [[ -z "$app_data" ]]; then
        echo "No applications found in batch account '${src_batch}'." >&2
        return 1
    fi

    echo "# Upload commands for target batch account: ${dst_batch} (${dst_rg})"
    echo "# Package directory: ${package_dir}"
    echo ""

    while IFS=$'\t' read -r app_name default_version <&3; do
        if [[ -z "$default_version" ]]; then
            echo "# SKIPPED ${app_name}: no default version set"
            continue
        fi
        local package_file="${package_dir}/${app_name}_${default_version}.zip"
        echo "package_and_upload_app \"${app_name}\" \"${default_version}\" \"${package_file}\" ${dst_batch} ${dst_rg}"
    done 3< <(echo "$app_data")
}

package_and_upload_pydelmod(){
    batch_name=$1
    resource_group_name=$2
    app_name="pydelmod"
    # todays date in 2024.06.11 format
    today=$(date +"%Y.%m.%d")
    version=${today}
    rm -rf /tmp/${app_name}_${version}
    mkdir -p /tmp/${app_name}_${version}
    pushd /tmp/${app_name}_${version}
    wget https://raw.githubusercontent.com/CADWRDeltaModeling/pydelmod/master/environment.yml
    sed -i '/- pyhecdss/i\  - libgfortran' environment.yml # add libgfortran to the environment.yml
    conda env remove -n ${app_name}_${version} -y || true
    conda env create -f environment.yml -n ${app_name}_${version}
    conda activate pack
    conda pack -n ${app_name}_${version} -o ${app_name}.tar.gz
    zip -r ${app_name}_${version}.zip ${app_name}.tar.gz
    conda deactivate
    conda env remove -n ${app_name}_${version} -y
    package_file="${app_name}_${version}.zip"

    module load azure_cli
    az batch application package create --application-name "${app_name}" --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${version}"
    az batch application set --application-name "${app_name}" --default-version "${version}" --name ${batch_name} --resource-group ${resource_group_name}
    popd
}



#package_and_upload_bdschism "../../BayDeltaSCHISM" schismbatch dwrbdo_schism_rg
#package_and_upload_bdschism "../../BayDeltaSCHISM" dwrbdodspbatch dwrbdo_dsp
#package_and_upload_telegraf "telegraf" schismbatch dwrbdo_schism_rg
#package_and_upload_telegraf "telegraf" dwrbdodspbatch dwrbdo_dsp
#package_and_upload_schism "schism" schismbatch dwrbdo_schism_rg
#package_and_upload_schism "schism" dwrbdodspbatch dwrbdo_dsp
#package_and_upload_batch_setup "../schism_scripts/" schismbatch dwrbdo_schism_rg
#package_and_upload_batch_setup "../schism_scripts/" dwrbdodspbatch dwrbdo_dsp
#az batch application package create --application-name schism_with_deps --name schismbatch --package-file schism_with_deps_5.11.1_alma8.7hpc_mvapich2.zip -g dwrbdo_schism_rg --version-name "5.11.1_alma8.7hpc_mvapich2"
#az batch application package create --application-name schism_with_deps --name schismbatch --package-file schism_with_deps_5.11.1_alma8.7hpc_v4_mvapich2.zip -g dwrbdo_schism_rg --version-name "5.11.1_alma8.7hpc_v4_mvapich2"
#az batch application package create --application-name schism_with_deps --name dwrbdodspbatch --package-file schism_with_deps_5.11.1_alma8.7hpc_mvapich2.zip -g dwrbdo_dsp --version-name "5.11.1_alma8.7hpc_mvapich2"
#az batch application package create --application-name schism_with_deps --name schismbatch --package-file schism_with_deps_5.11.1_alma8.7hpc_hpcx_pmix.zip -g dwrbdo_schism_rg --version-name "5.11.1_alma8.7hpc_hpcx_pmix"
#az batch application package create --application-name schism_with_deps --name schismbatch --package-file schism_with_deps_5.11.1_alma8.7hpc_hpcx.zip -g dwrbdo_schism_rg --version-name "5.11.1_alma8.7hpc_hpcx"
#az batch application package create --application-name mvapich2 --name schismbatch --package-file mvapich2-2.3.7-1-ndr-patch.zip -g dwrbdo_schism_rg --version-name "2.3.7-1-ndr-patch"
#az batch application package create --application-name schism_with_deps --name schismbatch --package-file schism_with_deps_v5.11.1_alma8.7hpc_mvapich2_ndr_patch.zip -g dwrbdo_schism_rg --version-name "5.11.1_alma8.7hpc_mvapich2_ndr_patch"
#package_and_upload_schimpy schismbatch dwrbdo_schism_rg
#package_and_upload_schimpy dwrbdodspbatch dwrbdo_dsp
#package_and_upload_pydelmod dwrmodelingbatchaccount azure_model_batch
#package_and_upload_suxarray dwrbdodspbatch dwrbdo_dsp
#package_and_upload_suxarray_with_deps schismbatch dwrbdo_schism_rg