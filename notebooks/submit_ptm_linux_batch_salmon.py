import os
import dmsbatch
import argparse
from dmsbatch import create_batch_client, create_blob_client
import datetime
import csv
import logging

client = create_batch_client('path_to_the_configuration_file')
blob_client = create_blob_client('path_to_the_configuration_file')
app_pkgs = [('ecoptmlinux', '8.2.54a9cc3c', 'DSM2-8.2.54a9cc3c-Linux/bin')]
pool_name = 'pool_name'
container_name='container_name'
tidefile_folder = 'tidefiles'
output_folder = 'outputs'

def create_pool():
    pool_start_cmds = ['printenv',
                       'yum install -y glibc.i686 libstdc++.i686 glibc.x86_64 libstdc++.x86_64',# --setopt=protected_multilib=false',
                       'yum-config-manager --add-repo https://yum.repos.intel.com/2019/setup/intel-psxe-runtime-2019.repo',
                       'rpm --import https://yum.repos.intel.com/2019/setup/RPM-GPG-KEY-intel-psxe-runtime-2019',
                       'yum install -y intel-icc-runtime-32bit intel-ifort-runtime-32bit']
    new_pool = client.create_pool(pool_name,
                        1,
                        app_packages=[(app,version) for app,version,_ in app_pkgs], 
                        vm_size='standard_f32s_v2', 
                        tasks_per_vm=32,
                        os_image_data=('openlogic', 'centos', '7_9'),
                        start_task_cmd=client.wrap_commands_in_shell(pool_start_cmds, ostype='linux'),
                        start_task_admin=True,
                        elevation_level='admin'
                        )
    #if the pool is already exist, Azure will use whatever the pool is configured.  if you'd like to use only one node, uncomment lines below
    #    client.resize_pool(pool_name,1)

def upload_prepare(blob_dir, study_folder, study_name, upload_tide_file=False):
    tidefile_blob_dir = blob_dir + '/' + tidefile_folder + '/' + study_name
    tide_file_local = '../%s/%s.h5' % (tidefile_folder, study_name)
    study_path = blob_dir + '/' + study_folder + '/' + study_name
    study_local_dir = './%s/%s' % (study_folder, study_name)
    job_name = '%s_%s' % (study_folder, study_name)
    # upload the tide file before the model run. 
    if upload_tide_file:
        # slow - 9 mins so use max_connections > 2 (default). Using 12 which seems to be a good fit here
        blob_client.upload_file_to_container(container_name,'%s/%s.h5'%(tidefile_blob_dir, study_name),tide_file_local, max_concurrency=10)
    input_tidefile = client.create_input_file_spec(container_name,blob_prefix='%s/%s.h5'%(tidefile_blob_dir, study_name),file_path='.')
    blob_client.zip_and_upload(container_name,'%s/%s.zip'%(study_path,study_name),study_local_dir,30)
    copy_tidefile_task = client.create_task_copy_file_to_shared_dir(container_name,'%s/%s.h5'%(tidefile_blob_dir, study_name),file_path='.',ostype='linux')
    client.create_job(job_name,pool_name,prep_task=copy_tidefile_task)
    return job_name

def create_ptm_single_task(release_day, envvars, study_path, study_name):
    input_file = client.create_input_file_spec(container_name,blob_prefix='%s/%s.zip'%(study_path,study_name),file_path='.')
    output_dir_sas_url = blob_client.get_container_sas_url(container_name)
    #std_out_files = client.create_output_file_spec(
        #'../std*.txt', output_dir_sas_url, blob_path=f'{study_path}/{output_folder}/{release_day}')
    #permissions = dmsbatch.commands.azureblob.BlobPermissions.WRITE
    output_dir_sas_url = blob_client.get_container_sas_url(container_name)
    output_dir = client.create_output_file_spec(
        f'{study_path}/studies/output/*', output_dir_sas_url, blob_path=f'{study_path}/{output_folder}/{release_day}')
    set_path_string = client.set_path_to_apps(app_pkgs, ostype='linux')
    zip_fname = study_name +'.zip'
    # batch file: no ";" before and no extra line after the last """  
    cmd_string = client.wrap_cmd_with_app_path(
        f"""
        source /opt/intel/psxe_runtime/linux/bin/compilervars.sh ia32;
        {set_path_string};
        cd {study_path};
        unzip {zip_fname}; 
        rm *.zip; 
        cd studies; 
        export TIDEFILE_LOC=$AZ_BATCH_NODE_SHARED_DIR; 
        sed -i 's+./output/DCP_EX.h5+${{TIDEFILE_LOC}}/{study_name}.h5+g' ptm.inp;
        sed -i -e "s/INSERTION_DATE_NAME/${{P_INSERT_DATE_NAME}}/g" ptm_behavior_inputs.inp; 
        sed -i -e "s|INSERTION_DATE|${{P_INSERT_DATE}}|g" ptm_behavior_inputs.inp;
        sed -i -e "s/STUDY_SCENARIO/${{DSM2_STUDY_NAME}}/g" ptm_behavior_inputs.inp;
        sed -i -e "s/INSERTION_DATE_NAME/${{P_INSERT_DATE_NAME}}/g" ptm.inp;
        ptm ptm.inp""", app_pkgs,ostype='linux')
    ptm_task = client.create_task(f'{study_name}_{release_day}', cmd_string,
                                  resource_files=[input_file],
                                  output_files=[output_dir],
                                  env_settings=envvars)
    #[output_dir, std_out_files]
    return ptm_task

def create_tasks(simulation_start_year,
               simulation_end_year,
               simulation_start_month,
               simulation_end_month,
               simulation_start_day,
               simulation_end_day,
               simulation_months,
               simulation_days,
               study_path,
               study_folder,
               study_name):
    tasks = []
    sim_days = datetime.timedelta(days=simulation_days)
    ten_days = datetime.timedelta(days=10)
    one_day = datetime.timedelta(days=1)
    #run the model for 10 days before insert the particles
    s_d  = datetime.date(simulation_start_year, simulation_start_month, simulation_start_day)
    e_d  = datetime.date(simulation_end_year, simulation_end_month, simulation_end_day)
    d = s_d
    while (d < e_d+one_day):
        if d.month in simulation_months:
            ptm_start_date = (d-ten_days).strftime("%d%b%Y")
            ptm_release_date = d.strftime("%d%b%Y")
            ptm_end_date = (d+sim_days).strftime("%d%b%Y")
            ptm_insert_date = d.strftime("%m/%d/%Y")
            ptm_insert_date_name = d.strftime("%m-%d-%Y")
            envvars = {'PTM_START_DATE': '%s' % ptm_start_date,
                       'PTM_END_DATE': '%s' % ptm_end_date, 
                       'DSM2_STUDY_NAME': '%s_%sP' % (study_name, study_folder[0:1]),
                       'P_INSERT_DATE': '%s' % ptm_insert_date,
                       'P_INSERT_DATE_NAME': '%s' % ptm_insert_date_name
                      }
            #print(ptm_start_date + "  "+ ptm_end_date + "  "+ptm_insert_date);
            task = create_ptm_single_task(ptm_release_date, envvars, study_path, study_name)
            tasks.append(task)
            
        d = d + one_day
    logging.info('All done!')
    return tasks

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='salmon particle migration and survival simulation')
    parser.add_argument('--start', type=int, nargs=3, required=True, help='start year start month and start day, e.g., 1999 2 1')
    parser.add_argument('--end', type=int, nargs=3, required=True, help='end year end month and end day, e.g., 2016 6 30')
    parser.add_argument('--months', nargs='+', type=int, default=[
                        1, 2, 3, 4, 5, 6, 10, 11, 12], help='list of months 1-12 for which to run simulations, e.g. 1 2 3 for JAN FEB MAR')
    parser.add_argument('--simulation-days', type=int, default=92,
                        help='simulation days, e.g. 150')
    parser.add_argument('--study-name', type=str, required=True,
                        help='name of study, also name of subfolder under study folder option which contains the input setup')
    parser.add_argument('--study-folder', type=str, required=True,
                        help='name of study folder under which study name will be found which contains the input setup')
    parser.add_argument('--blobdir', type=str, default='tests',
                        help='name of the top level blob container directory')
    parser.add_argument('--upload-tidefile', type=bool, default=False,
                        help='''upload tidefiles''')
    args = parser.parse_args()
    print('Running with args: ', args)
    simulation_start_year, simulation_start_month, simulation_start_day = args.start[0], args.start[1], args.start[2]
    simulation_end_year, simulation_end_month, simulation_end_day = args.end[0], args.end[1], args.end[2]
    blob_dir = args.blobdir
    upload_tidefile = args.upload_tidefile
    study_name = args.study_name
    study_folder = args.study_folder
    study_path = blob_dir + '/' + study_folder + '/' + study_name
    create_pool()
    job_name = upload_prepare(blob_dir,study_folder,study_name,upload_tidefile)
    tasks = create_tasks(simulation_start_year,simulation_end_year,simulation_start_month,simulation_end_month,
                        simulation_start_day,simulation_end_day,args.months,args.simulation_days,study_path,study_folder,study_name)
    # Azure batch limits to submitting 100 tasks at a time.
    for i in range(0,round(len(tasks)/100)):
        client.submit_tasks(job_name,tasks[i*100:i*100+100])
    client.submit_tasks(job_name,tasks[i*100:])
    
    # ## Finally resize the pool to 0 to save costs
    #client.resize_pool(pool_name,0)
