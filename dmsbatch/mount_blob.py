import sys
import os
import click
import pkg_resources
import datetime
import json
import subprocess
import tempfile

CONTEXT_SETTINGS = dict(help_option_names=['-h', '--help'])

@click.group(context_settings=CONTEXT_SETTINGS)
def main():
    pass

def get_storage_account_key(resource_group_name, storage_account_name):
    '''make sure az cli is logged in to the correct subscription. 
    Use az login --use-device-code to login to the correct subscription.'''
    cmd = f'az storage account keys list --account-name {storage_account_name} --resource-group {resource_group_name}'
    key_dict = json.loads(subprocess.check_output(cmd, shell=True).decode('utf-8').strip())
    return key_dict[0]['value']

@click.command(name='mount-blob', help='Mount a blob container')
@click.option('--resource-group-name', required=True, help='Name of the resource group')
@click.option('--storage-account-name', required=True, help='Name of the storage account')
@click.option('--container-name', required=True, help='Name of the container')
@click.option('--mount-point', default='/mnt/resource/blobs', help='Mount point for the container')
@click.option('--read-only', is_flag=True, default=False, help='Mount the container in read-only mode')
@click.option('--cache-size-mb', default=1024, help='Size of the cache (mounted at {mount-point}/.tmp{container-name}) in MB')
def mount_blob(resource_group_name, storage_account_name, container_name, 
                mount_point='/mnt/resource/blobs', read_only=False, cache_size_mb=1024):
    '''make sure az cli is logged in to the correct subscription. 
    Use az login --use-device-code to login to the correct subscription.'''
    if 'STORAGE_ACCOUNT_KEY' in os.environ: # get key from environment variable
        storage_account_key = os.environ['STORAGE_ACCOUNT_KEY']
    else:
        storage_account_key = get_storage_account_key(resource_group_name, storage_account_name)
    template = pkg_resources.resource_string(__name__, 'blob_mount_config_template.yml').decode('utf-8')
    template = template.format(storage_account_name=storage_account_name,
                               storage_account_key=storage_account_key,
                               container_name=container_name,
                               mount_point=mount_point,
                               read_only=str(read_only).lower(),
                               cache_size_mb=cache_size_mb)
    dtstr = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    try:
        # Create a temporary directory
        temp_dir = tempfile.mkdtemp()
        tmp_config_fname = f'{temp_dir}/temp_config_template_{dtstr}.yml'
        with open(tmp_config_fname,'w') as fh:
            fh.write(template)
        subprocess.check_output(f'mkdir -p {mount_point}/.tmp{container_name}', shell=True)
        subprocess.check_output(f'mkdir -p {mount_point}/{container_name}', shell=True)
        subprocess.check_output(f'blobfuse2 mount {mount_point}/{container_name} --config-file={tmp_config_fname}', shell=True)
        print(f'Blob container {container_name} mounted at {mount_point}/{container_name}')
    finally:
        subprocess.check_output(f'rm -f {tmp_config_fname}', shell=True)

@click.command(name='unmount-all-blobs', help='Unmount all blobfus mounted containers')
def unmount_all_blobs():
    subprocess.check_output('blobfuse2 unmount all', shell=True)

main.add_command(mount_blob)
main.add_command(unmount_all_blobs)

if __name__ == '__main__':
    sys.exit(main())
