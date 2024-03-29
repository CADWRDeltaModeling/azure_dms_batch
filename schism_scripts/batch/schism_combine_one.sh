#!/bin/bash

set -e          # Exit immediately if a command exits with a non-zero status
set -o pipefail # Exit if any command in a pipeline exits with a non-zero status
# set base_url to the first argument, or the default value if no argument is given
base_url=${1}
# set blob_path to the second argument, or the default value if no argument is given
blob_path=${2}
# set sas_token to the third argument, or the default value if no argument is given
sas_token=${3}
# set day_index to the fourth argument, or 0 if no argument is given
day_index=${4}
# set number of combine files to the fifth argument, or 0 if no argument is given
num_combine_files=${5:-0}

# if num_combine_files is 0, then use include pattern to get all files
if [ $num_combine_files -eq 0 ]; then
    azcopy cp "${base_url}?${sas_token}" "." --include-pattern "schout*_${day_index}.nc"
else
    # loop from 0 to num_combine_files-1
    for i in $(seq 0 $(($num_combine_files-1))); do
        # set processor_no to i with 4 digits that are zero padded
        processor_no=$(printf "%04d" $i)
        echo "schout_${processor_no}_${day_index}.nc" >> combine_list.txt
    done
    azcopy cp "${base_url}?${sas_token}" "." --list-of-files combine_list.txt
fi

# Try to load environment modules using the module command
if ! command -v module &> /dev/null; then
    # If the module command is not found, source the module initialization file and try again
    source /usr/share/Modules/init/bash
    if ! command -v module &> /dev/null; then
        echo "Error: Unable to load environment modules. Aborting."
        exit 1
    fi
fi

# source here because otherwise the above commands will fail
module load hdf5 netcdf-c netcdf-fortran schism
source /opt/intel/oneapi/compiler/latest/env/vars.sh
ulimit -s unlimited
# combine the files
combine_output11 -b ${day_index} -e ${day_index}
# clean up
wait
