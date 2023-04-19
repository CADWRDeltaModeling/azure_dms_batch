import os
import dmsbatch
import argparse
from dmsbatch import create_batch_client, create_blob_client
import datetime
import csv
import logging

client = create_batch_client('path_to_the_configuration')
blob_client = create_blob_client('path_to_the_configuration')
app_pkgs = [('ecoptmlinux', '8.2.54a9cc3c', 'DSM2-8.2.54a9cc3c-Linux/bin')]
pool_name = 'pool_name'
container_name='container_name'
tidefile_folder = 'tidefiles'
output_folder = 'outputs'
scripts_folder = 'scripts'
dss_env_file = 'ptmbatch.tar.gz'
dss_read_script = 'ptm_fate_postpro_single.py'

def create_pool():
    pool_start_cmds = ['printenv',
                       'yum install -y glibc.i686 libstdc++.i686 glibc.x86_64 libstdc++.x86_64',# --setopt=protected_multilib=false',
                       'yum-config-manager --add-repo https://yum.repos.intel.com/2019/setup/intel-psxe-runtime-2019.repo',
                       'rpm --import https://yum.repos.intel.com/2019/setup/RPM-GPG-KEY-intel-psxe-runtime-2019',
                       'yum install -y intel-icc-runtime-32bit intel-ifort-runtime-32bit',
                       'yum install libgfortran4 -y']
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
    #copy_tidefile_task = client.create_task_copy_file_to_shared_dir(container_name,'%s/%s.h5'%(tidefile_blob_dir, study_name),file_path='.',ostype='linux')
    dss_env = client.create_input_file_spec(container_name, '%s/%s'%(scripts_folder, dss_env_file), file_path='.')
    #dss_reader = client.create_input_file_spec(container_name, '%s/%s'%(scripts_folder, dss_read_script), file_path='.')
    az_shared_dir = '${AZ_BATCH_NODE_SHARED_DIR}'
    commands = ["printenv",
        "rm -rf ${AZ_BATCH_NODE_SHARED_DIR}/pydelmod",
        f"mv {tidefile_blob_dir}/{study_name}.h5 {az_shared_dir}",
        "mkdir -p ${AZ_BATCH_NODE_SHARED_DIR}/pydelmod",
        f"mv {scripts_folder}/{dss_env_file} {az_shared_dir}/pydelmod",
        "cd ${AZ_BATCH_NODE_SHARED_DIR}/pydelmod",
        "tar xvzf ptmbatch.tar.gz",
        'echo "Done setting up pydelmod!"']
    startup_task = client.create_prep_task('startup_task',commands, resource_files=[input_tidefile, dss_env],ostype='linux') 
    client.create_job(job_name,pool_name,prep_task=startup_task)
    #client.create_job(job_name,pool_name,prep_task=copy_tidefile_task)
    return job_name

def create_ptm_single_task(release_day, run_no, envvars, study_path, study_name):
    input_file = client.create_input_file_spec(container_name,blob_prefix='%s/%s.zip'%(study_path,study_name),file_path='.')
    output_dir_sas_url = blob_client.get_container_sas_url(container_name)
    #std_out_files = client.create_output_file_spec(
    #    '../std*.txt', output_dir_sas_url, blob_path=f'{study_path}/{output_folder}/{release_day}/{run_no}')
    #permissions = dmsbatch.commands.azureblob.BlobPermissions.WRITE
    output_dir = client.create_output_file_spec(
        f'{run_no}/*', output_dir_sas_url, blob_path=f'{study_path}/{output_folder}/{release_day}/{run_no}')
    set_path_string = client.set_path_to_apps(app_pkgs, ostype='linux')
    zip_fname = study_name+'.zip'
    # batch file: no ";" before and no extra line after the last """  
    az_shared_dir = '${AZ_BATCH_NODE_SHARED_DIR}'
    cmd_string = client.wrap_cmd_with_app_path(
        f"""
        mkdir -p $AZ_BATCH_TASK_WORKING_DIR/{run_no};
        echo "done create directory";
        source /opt/intel/psxe_runtime/linux/bin/compilervars.sh ia32;
        source {az_shared_dir}/pydelmod/ptmbatch/bin/activate;
        {set_path_string};
        cd {study_path};
        unzip {zip_fname}; 
        rm *.zip;
        cd studies; 
        export TIDEFILE_LOC=$AZ_BATCH_NODE_SHARED_DIR; 
        sed -i 's+./output/DCP_EX.h5+${{TIDEFILE_LOC}}/{study_name}.h5+g' planning_ptm.inp;
        ptm planning_ptm.inp; 
        rm output/trace.out;
        echo "done remove trace file";
        cd output;
        python ptm_fate_postpro_single.py --start {release_day} --runno {run_no};
        cd ../;
        mv output/* $AZ_BATCH_TASK_WORKING_DIR/{run_no}""", app_pkgs,ostype='linux')
        #mv ../../../../std*.txt $AZ_BATCH_TASK_WORKING_DIR
    #print(cmd_string)
    ptm_task = client.create_task(f'{study_name}_{release_day}_{run_no}', cmd_string,
                                  resource_files=[input_file],
                                  output_files=[output_dir], #, std_out_files],
                                  env_settings=envvars)
    return ptm_task

def create_tasks(simulation_start_year,
               simulation_end_year,
               simulation_start_day,
               simulation_months,
               simulation_days,
               study_path,
               study_folder,
               study_name,
               insertion_file,
               duration,
               delay):
    tasks = []
    sim_days = datetime.timedelta(days=simulation_days)
    with open(insertion_file, 'r') as input:
        for row in csv.DictReader(input):  # run#,particle#,node
            run_no = row['run#']
            particle_no = row['particle#']
            insertion_node = row['node']
            job_name_prefix = 'ptm-%s-%s-%s' % (
                study_folder[0:5], study_name, run_no)                                           
            for y in range(simulation_start_year, simulation_end_year+1):
                for m in simulation_months:
                    s_day = datetime.date(y, m, simulation_start_day)
                    e_day = s_day + sim_days
                                                                   
                    ptm_start_date = s_day.strftime("%d%b%Y").upper()
                    ptm_end_date = e_day.strftime("%d%b%Y").upper()
                    particle_insertion_row = '%s %s %s %s' % (
                        insertion_node, particle_no, delay, duration)
                    envvars = {'RUN_NO': '%s' % run_no,
                               'PTM_START_DATE': '%s' % ptm_start_date,
                               'PTM_END_DATE': '%s' % ptm_end_date,
                               'PARTICLE_INSERTION_ROW': '%s' % particle_insertion_row,
                               'DSM2_STUDY_NAME': 'LTO_%s_%sP' % (study_name, study_folder[0:1])
                               }                                                                               
                    task = create_ptm_single_task(ptm_start_date, run_no, envvars, study_path, study_name) 
                    tasks.append(task)                                
    logging.info('All done!')
    return tasks

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='extract PTM particle fates')
    parser.add_argument('--insertion-file', type=str, default='run_number_loc.txt',
                        help='''insertion file with run and insertion info for particles. See sample below
                                run#,particle#,node
                                1,4000,1
                                2,4000,7    
                                3,4000,21''')
    parser.add_argument('--start-year', type=int, required=True,
                        help='Start year as 4 digit year, e.g. 2003')
    parser.add_argument('--end-year', type=int, required=True,
                        help='End year as 4 digit year, e.g. 2004')
    parser.add_argument('--start-day', type=int, default=1,
                        help='day number of month to start simulation, e.g. 5')
    parser.add_argument('--months', nargs='+', type=int, default=[
                        1, 2, 3, 4, 5, 6], help='list of months 1-12 for which to run simulations, e.g. 1 2 3 for JAN FEB MAR')
    parser.add_argument('--run-length', type=int, default=92,
                        help='number of days for simulation run, e.g. 122')
    parser.add_argument('--duration', type=str, default='1485minutes',
                        help='duration of insertion of particles in format <number><interval>, e.g. 1day or 1485minutes')
    parser.add_argument('--delay', type=str, default='0day',
                        help='delay from start of simulation to insert particles, e.g. 5minutes or 1day')
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

    blob_dir = args.blobdir
    upload_tidefile = args.upload_tidefile
    study_name = args.study_name
    study_folder = args.study_folder
    study_path = blob_dir + '/' + study_folder + '/' + study_name
    
    create_pool()
    job_name = upload_prepare(blob_dir,study_folder,study_name,upload_tidefile)
    tasks = create_tasks(args.start_year,args.end_year,args.start_day,
                    args.months,args.run_length,study_path,study_folder,study_name,args.insertion_file,args.duration,args.delay)
    # Azure batch limits to submitting 100 tasks at a time.
    for i in range(0,round(len(tasks)/100)):
        client.submit_tasks(job_name,tasks[i*100:i*100+100])
    client.submit_tasks(job_name,tasks[i*100:])
    
    # ## Finally resize the pool to 0 to save costs
    #client.resize_pool(pool_name,0)
