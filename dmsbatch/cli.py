import dmsbatch
from dmsbatch import __version__
from dmsbatch import commands
from dmsbatch import batch
from dmsbatch import mount_blob

import click
import sys

CONTEXT_SETTINGS = dict(help_option_names=["-h", "--help"])


@click.group(context_settings=CONTEXT_SETTINGS)
def main():
    pass


@click.command()
@click.option("--file", prompt="generate sample config file", help="config file")
def config_generate_cmd(file):
    commands.generate_blank_config(file)


@click.group()
def schism():
    pass


@click.command(help="submits job using the config file specified")
@click.option(
    "--file",
    prompt="config file",
    help="config file describing the job to be submitted.",
)
@click.option(
    "--pool-name",
    help="The pool name if specified means the pool already exists and so would not be created but used",
    required=False,
)
# add a log level option that allows for DEBUG, INFO, WARNING, ERROR, CRITICAL
@click.option(
    "--log-level",
    default="INFO",
    type=click.Choice(
        ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], case_sensitive=False
    ),
    help="The log level to use. Default is INFO",
    show_default=True,
)
def submit_job(file, pool_name=None, log_level="INFO"):
    batch.setup_logging(log_level)
    batch.submit_job(file, pool_name)


@click.command(help="creates a pool using the config file specified")
@click.option(
    "--file",
    prompt="config file",
    help="config file describing the pool to be created.",
    required=True,
)
@click.option(
    "--pool-name",
    help="The pool name to be created.",
    required=False,
)
# add a log level option that allows for DEBUG, INFO, WARNING, ERROR, CRITICAL
@click.option(
    "--log-level",
    default="INFO",
    type=click.Choice(
        ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], case_sensitive=False
    ),
    help="The log level to use. Default is INFO",
    show_default=True,
)
def create_pool(file, pool_name, log_level):
    batch.setup_logging(log_level)
    batch.create_pool_from_config(file, pool_name)


@click.command(help="set batch and storage account keys")
@click.option(
    "--resource-group-name", prompt="resource group name", help="resource group name"
)
@click.option(
    "--batch-account-name", prompt="batch account name", help="batch account name"
)
@click.option(
    "--storage-account-name", prompt="storage account name", help="storage account name"
)
def set_keys(resource_group_name, batch_account_name, storage_account_name):
    batch_account_key = batch.get_batch_account_key(
        resource_group_name, batch_account_name
    )
    storage_account_key = batch.get_storage_account_key(
        resource_group_name, storage_account_name
    )
    if sys.platform == "win32":
        with open("keys.bat", "w") as f:
            f.write("set BATCH_ACCOUNT_KEY={}\n".format(batch_account_key))
            f.write("set STORAGE_ACCOUNT_KEY={}\n".format(storage_account_key))
        print("Batch and storage account keys written to keys.bat")
        print(
            "Run keys.bat to set environment variables before using dmsbatch submit-job to submit jobs. Delete it when done for security."
        )
        print("call keys.bat && del keys.bat")
    else:
        with open("keys.sh", "w") as f:
            f.write("export BATCH_ACCOUNT_KEY={}\n".format(batch_account_key))
            f.write("export STORAGE_ACCOUNT_KEY={}\n".format(storage_account_key))
        print("Batch and storage account keys written to keys.sh")
        print(
            "Run source keys.sh to set environment variables before using dmsbatch schism to submit jobs. Delete it when done for security."
        )
        print("source keys.sh && rm keys.sh")


@click.command(help="upload batch scripts to storage account")
@click.option(
    "--resource-group-name", prompt="resource group name", help="resource group name"
)
@click.option(
    "--storage-account-name", prompt="storage account name", help="storage account name"
)
def upload_batch_scripts(resource_group_name, storage_account_name):
    batch.upload_batch_scripts(resource_group_name, storage_account_name)


schism.add_command(submit_job, name="submit-job")
schism.add_command(set_keys, name="set-keys")
schism.add_command(upload_batch_scripts, name="upload-batch-scripts")


main.add_command(config_generate_cmd, name="config-generate")
main.add_command(schism, name="schism")
main.add_command(submit_job, name="submit-job")
main.add_command(create_pool, name="create-pool")
main.add_command(mount_blob.mount_blob, name="mount-blob")
main.add_command(mount_blob.unmount_all_blobs)


if __name__ == "__main__":
    sys.exit(main())
