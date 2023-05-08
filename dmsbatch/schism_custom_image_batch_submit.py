from dmsbatch import create_batch_client, create_blob_client
from azure.batch.models import BatchErrorException
import datetime
client = create_batch_client('../tests/data/schismbatch.config')
blob_client = create_blob_client('../tests/data/schismbatch.config')
vm_core_map={'standard_hc44rs':44,'standard_hb120rs_v2':120}
vm_size= 'standard_hb120rs_v2'# 'standard_hc44rs' #
num_hosts=3 # TEST ONLY: change with num_hosts
num_cores=num_hosts*(vm_core_map[vm_size]-5) # change with the vm_size, reserve 5 cores per node for other activities
# num_cores=220 # TEST ONLY:  override for test, remove after
num_scribes=6 #  number of schism scribes, depends upon the schism setup
# copy setup directories from blob storage to the batch pool
# relative to the $AZ_BATCH_NODE_MOUNTS_DIR is the name of container and then path
setup_dirs= ["test/vansickle2020/atmospheric_data", "test/vansickle2020/ts"]
study_dir="test/vansickle2020/base_barclinic"
batch_scripts_dir="batch" # relative to the $AZ_BATCH_NODE_MOUNTS_DIR is the name of container (batch) and then path
pool_name='schismpool510'
job_name='schismjobs510'
try:
    client.create_job(job_name,pool_name)
except BatchErrorException as e:
    if e.error.code == 'JobExists':
        print('Job already exists')
    else:
        raise e
import os
# name task with date and time
task_name = f'schism510_{datetime.datetime.now().strftime("%Y_%m_%d_%H_%M_%S")}'
cmd_string = f"""
echo Main task $(pwd);
source /usr/share/Modules/init/bash;
source /opt/intel/compilers_and_libraries/linux/bin/compilervars.sh intel64;
module load hdf5/1.10.8 netcdf-c/4.8.1 netcdf-fortran/4.5.3 schism/5.10.0 mpi/impi-2021;
ulimit -s unlimited;
echo "Copying from blob to local for the setup first time";
cd simulations;
mkdir -p $(dirname {study_dir});
"""
for dir in setup_dirs + [study_dir]:
    cmd_string += f"rsync -av --exclude='outputs/' --no-perms $AZ_BATCH_NODE_MOUNTS_DIR/{dir} $(dirname {dir});\n"
cmd_string += f"""mkdir -p {study_dir}/outputs;"""
cmd_string += f"""bash $AZ_BATCH_NODE_MOUNTS_DIR/{batch_scripts_dir}/copy_modified_loop.sh {study_dir} $AZ_BATCH_NODE_MOUNTS_DIR&
pid=$!;
echo "Running background copy_modified_loop.sh with pid $pid";"""
cmd_string += f"""cd {study_dir};
echo "Running schism with {num_cores} cores and {num_hosts} hosts";
export I_MPI_FABRICS=shm:ofi;
export I_MPI_OFI_PROVIDER=mlx;
mpiexec -n {num_cores} -ppn {num_hosts} -hosts $AZ_BATCH_HOST_LIST pschism_PREC_EVAP_GOTM_TVD-VL {num_scribes};
sleep 300;
echo Done"""
cmd_string = client.wrap_cmd_with_app_path(cmd_string,[],ostype='linux')
# coordination task, commands to be run on all nodes
coordination_cmd = f"""
echo 'running beeond install script';
source $AZ_BATCH_NODE_MOUNTS_DIR/{batch_scripts_dir}/beeond_start.sh;
echo "linking to beeond mount as simulations and changing directory to simulations";
ln -s /mnt/beeond $AZ_BATCH_TASK_WORKING_DIR/simulations;
echo Done"""
print(task_name)
print(cmd_string)
print(coordination_cmd)
schism_task = client.create_task(task_name,cmd_string,
                                num_instances=num_hosts,
                                coordination_cmdline=coordination_cmd)
client.submit_tasks(job_name,[schism_task])
# wait for the tasks to complete and then resize the pool to 0
#client.wait_for_tasks_to_complete(job_name,timeout=datetime.timedelta(seconds=120))
#client.resize_pool(pool_name,0)


