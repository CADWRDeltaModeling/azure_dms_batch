#!/bin/env bash

package_and_upload_telegraf() {
    telegraf_dir=$1
    batch_name=$2
    resource_group_name=$3

    pushd $telegraf_dir
    version="1.31.0"
    package_file="telegraf_${version}.zip"
    zip -r "../${package_file}" *

    popd
    module load azure_cli
    az batch application package create --application-name telegraf --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${version}"

}

package_and_upload_bdschism() {
    bdschism_dir=$1
    batch_name=$2
    resource_group_name=$3

    pushd $bdschism_dir

    # todays date in 2024.06.11 format
    today=$(date +"%Y.%m.%d")
    package_file="BayDeltaSCHISM_${today}.zip"
    zip -r "../azure_dms_batch/app-packages/${package_file}" *

    popd
    module load azure_cli
    az batch application package create --application-name BayDeltaSCHISM --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${today}"
}

package_and_upload_schism() {
    schism_dir=$1
    batch_name=$2
    resource_group_name=$3

    version="5.11_alma8.7hpc"
    package_file="schism_${version}.zip"
    zip -r "${package_file}" $schism_dir

    module load azure_cli
    az batch application package create --application-name schism_with_deps --name ${batch_name} --package-file "${package_file}" -g ${resource_group_name} --version-name "${version}"
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
}
# Call the function
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
