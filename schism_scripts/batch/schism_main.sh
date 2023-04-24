# main task
n_cores=${1}
num_hosts=${2}
n_scribes=${3}
wdir=${4} # -wdir option for mpirun doesn't work!
source $AZ_BATCH_TASK_SHARED_DIR/schism_init.sh
#
echo "Initializing Intel oneAPI"
source /opt/intel/oneapi/setvars.sh intel64
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=mlx
#export I_MPI_HYDRA_IFACE="ib0" # community.intel.com/t5/Intel-oneAPI-HPC-Toolkit/Intel-MPI-Unable-to-run-bstrap-proxy-error-setting-up-the/m-p/1379558#M9442
#
echo "Launching SCHISM"
echo "Changing to working directory: ${wdir}"
cd ${wdir}
echo "in working directory: `pwd`"
echo "Running command: mpirun -n $n_cores -ppn $num_hosts -hosts $AZ_BATCH_HOST_LIST bash $AZ_BATCH_TASK_SHARED_DIR/schism_azure.sh ${n_scribes}"
mpirun -n $n_cores -ppn $num_hosts -hosts $AZ_BATCH_HOST_LIST bash $AZ_BATCH_TASK_SHARED_DIR/schism_azure.sh ${n_scribes}
echo "SCHISM finished"
