import os
import dmsbatch
from dmsbatch import create_batch_client, create_blob_client
import datetime
import argparse
import logging

client = create_batch_client('path_to_the_configuration')
blob_client = create_blob_client('path_to_the_configuration')
app_pkgs = [('ecoptmlinux', '8.2.54a9cc3c', 'DSM2-8.2.54a9cc3c-Linux/bin'), ('dsm2_linux_rpms', '1.0.0','')]
pool_name = 'pool_name'
container_name='container_name'
output_folder = 'outputs'
scripts_folder = 'scripts'
dss_env_file = 'ptmbatch.tar.gz'

def create_pool():
    client.create_pool(pool_name,
                    1,
                    app_packages=[(app,version) for app,version,_ in app_pkgs], 
                    vm_size='Standard_D11_v2', # 'Standard_F32s_v2', #standard_f2s_v2' -- too small disk size for task
                    tasks_per_vm=1,
                    os_image_data=('openlogic', 'centos', '7_9'),
                    start_task_cmd=client.wrap_commands_in_shell(['printenv', 'yum install libgfortran4 -y'], ostype='linux'),
                    start_task_admin=True,
                    elevation_level='admin'
                    )

def upload_prepare(blob_dir, study_folder, study_name,merge_script):
    job_name = '%s_%s_merge' % (study_folder, study_name)
    dss_env = client.create_input_file_spec(container_name, '%s/%s'%(scripts_folder, dss_env_file), file_path='.')
    az_shared_dir = '${AZ_BATCH_NODE_SHARED_DIR}'
    commands = ["printenv",
        "mkdir -p ${AZ_BATCH_NODE_SHARED_DIR}/pydelmod",
        f"mv {scripts_folder}/{dss_env_file} {az_shared_dir}/pydelmod",
        "cd ${AZ_BATCH_NODE_SHARED_DIR}/pydelmod",
        "tar xvzf ptmbatch.tar.gz",
        'echo "startup task!"']
    startup_task = client.create_prep_task('startup_task', commands, resource_files=[dss_env],ostype='linux') 
    client.create_job(job_name,pool_name,prep_task=startup_task)
    return job_name

def create_ptm_fate_merge_task(start,end,months,days,study_path,study_folder,study_name,merge_script,file_prefix):
    output_path = study_path + '/' + output_folder
    results_files = client.create_input_file_spec(container_name,output_path,file_path='.')
    merge_script_file = client.create_input_file_spec(container_name,'%s/%s'%(scripts_folder, merge_script), file_path='.')
    output_dir_sas_url = blob_client.get_container_sas_url(container_name) 
    output_dat_files = client.create_output_file_spec(
        f'{output_path}/{file_prefix}', output_dir_sas_url, blob_path=f'{study_path}')
    az_shared_dir = '${AZ_BATCH_NODE_SHARED_DIR}'
    cmd_string = client.wrap_cmd_with_app_path(
        f"""
        source {az_shared_dir}/pydelmod/ptmbatch/bin/activate;
        mv {scripts_folder}/{merge_script} {output_path}; 
        cd {output_path};
        python {merge_script} --start {start} --end {end} --months {months} --days {days}""", app_pkgs,ostype='linux')        
    merge_task = client.create_task(study_name + '_merge',cmd_string,
                                            resource_files=[results_files,merge_script_file],output_files=[output_dat_files],env_settings={})
    return merge_task

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='extract PTM particle fates')
    parser.add_argument('--start',type=int,nargs=3,required=True,help='Start year month day')
    parser.add_argument('--end',type=int,nargs=3,required=True,help='End year month day')
    parser.add_argument('--months', nargs='+', type=int, default=[1, 2, 3, 4, 5, 6], 
                        help='list of months 1-12 for which to run simulations, e.g. 1 2 3 for JAN FEB MAR')
    parser.add_argument('--days', nargs='+', type=int, default=[90,30], help='days for results, e.g. 30 90')
    parser.add_argument('--study-name', type=str, required=True,
            help='name of study, also name of subfolder under study folder option which contains the input setup')
    parser.add_argument('--study-folder', type=str, required=True,
                        help='name of study folder under which study name will be found which contains the input setup')
    parser.add_argument('--blobdir', type=str, default='tests',help='name of the top level blob container directory')
    parser.add_argument('--script', type=str, default='ptm_fate_merge_np.py',help='name of the merge script')
    parser.add_argument('--filePrefix', type=str, default='ptm*.dat',help='merged file names')
    args = parser.parse_args()
    print('Running with args: ', args)
    start = args.start
    start_str = str(start[0])+" "+str(start[1])+" "+str(start[2])
    end = args.end
    end_str = str(end[0])+" "+str(end[1])+" "+str(end[2])
    months_str=''
    for m in args.months:
        months_str += str(m) + " "
    days_str =''
    for d in args.days:
        days_str += str(d) + " "
    blob_dir = args.blobdir
    study_name = args.study_name
    study_folder = args.study_folder
    study_path = blob_dir + '/' + study_folder + '/' + study_name   
    create_pool()
    job_name = upload_prepare(blob_dir,study_folder,study_name,args.script)
    task = create_ptm_fate_merge_task(start_str,end_str,months_str,days_str,
                study_path,study_folder,study_name,args.script,args.filePrefix)
    client.submit_tasks(job_name,[task])
