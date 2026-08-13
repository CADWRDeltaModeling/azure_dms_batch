"""Copy a folder from one Blob container/path to another, possibly in a different storage account.

Regular blob data is copied server-side with a single recursive azcopy Blob->Blob transfer.
Symlink placeholder blobs (uploaded via `azcopy copy --preserve-symlinks`, tagged with
metadata `is_symlink=true`) are re-copied individually afterwards via the Storage Blob SDK,
to guarantee their metadata survives the transfer.

SAS tokens are obtained the same way as for job submission (dmsbatch.batch.get_sas): via the
STORAGE_ACCOUNT_KEY environment variable if set, otherwise by looking up the storage account
key with the az cli (dmsbatch.batch.get_storage_account_key).
"""

import logging
import os
import subprocess
import sys
import time

import click
from azure.storage.blob import BlobServiceClient, ContainerClient

from dmsbatch import batch

logger = logging.getLogger(__name__)


def setup_logging(log_level=logging.INFO):
    """batch.setup_logging only attaches a handler to its own/commands' loggers, so do it here too."""
    logger.setLevel(log_level)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(levelname)s:%(name)s %(message)s"))
    logger.addHandler(handler)


def _get_storage_account_key(resource_group_name, storage_account_name):
    if "STORAGE_ACCOUNT_KEY" in os.environ:
        logger.debug("using storage account key from environment variable")
        return os.environ["STORAGE_ACCOUNT_KEY"]
    logger.debug("using storage account key from az cli")
    return batch.get_storage_account_key(resource_group_name, storage_account_name)


def get_container_sas(
    resource_group_name,
    storage_account_name,
    container_name,
    permissions="acdlrw",
    expires_in_days=1,
):
    storage_account_key = _get_storage_account_key(
        resource_group_name, storage_account_name
    )
    return batch.get_sas(
        storage_account_name,
        storage_account_key,
        container_name,
        permissions=permissions,
        expires_in_days=expires_in_days,
    )


def copy_blob_data(
    src_storage_account_name,
    src_container,
    src_path,
    src_sas,
    dst_storage_account_name,
    dst_container,
    dst_path,
    dst_sas,
    overwrite="false",
):
    """Recursive server-side (Blob->Blob) copy of the data under src_path.

    Blob metadata (including is_symlink) is preserved by default; --as-subdir=false
    ensures dst_path is used literally instead of nesting src_path's leaf name under it.
    """
    src_url = f"https://{src_storage_account_name}.blob.core.windows.net/{src_container}/{src_path}?{src_sas}"
    dst_url = f"https://{dst_storage_account_name}.blob.core.windows.net/{dst_container}/{dst_path}?{dst_sas}"
    # NOTE: --s2s-preserve-blob-tags requires an extra 't' SAS permission we don't request (we only
    # need blob metadata preserved, which azcopy does by default - not Blob Index Tags), so it's omitted.
    cmd = (
        f'azcopy copy "{src_url}" "{dst_url}" --from-to=BlobBlob --recursive=true --as-subdir=false '
        f"--check-length=true --s2s-preserve-access-tier=false "
        f"--include-directory-stub=false --overwrite={overwrite} --log-level=INFO"
    )
    logger.info(
        f"copying data {src_storage_account_name}/{src_container}/{src_path} -> "
        f"{dst_storage_account_name}/{dst_container}/{dst_path}"
    )
    subprocess.check_call(cmd, shell=True)


def copy_symlink_blobs(
    src_storage_account_name,
    src_container,
    src_path,
    src_sas,
    dst_storage_account_name,
    dst_container,
    dst_path,
    dst_sas,
    overwrite=False,
    dry_run=False,
):
    """Re-copy blobs tagged with metadata is_symlink=true so their metadata always survives the transfer."""
    src_account_url = f"https://{src_storage_account_name}.blob.core.windows.net"
    dst_account_url = f"https://{dst_storage_account_name}.blob.core.windows.net"
    src_prefix = src_path.rstrip("/") + "/" if src_path else ""
    dst_prefix = dst_path.rstrip("/") + "/" if dst_path else ""

    src_client = ContainerClient(
        account_url=src_account_url, container_name=src_container, credential=src_sas
    )
    dst_service = BlobServiceClient(account_url=dst_account_url, credential=dst_sas)
    dst_container_client = dst_service.get_container_client(dst_container)

    symlinks = [
        b
        for b in src_client.list_blobs(name_starts_with=src_prefix, include=["metadata"])
        if (b.metadata or {}).get("is_symlink") == "true"
    ]
    logger.info(f"found {len(symlinks)} symlink blob(s) under {src_container}/{src_prefix}")

    copied = skipped = failed = 0
    for blob in symlinks:
        dst_blob_name = dst_prefix + blob.name[len(src_prefix):]
        dst_blob_client = dst_container_client.get_blob_client(dst_blob_name)

        if dry_run:
            logger.info(f"  [dry-run] would copy {blob.name} -> {dst_blob_name}")
            continue

        if not overwrite:
            try:
                dst_blob_client.get_blob_properties()
                logger.info(f"  SKIP (exists): {dst_blob_name}")
                skipped += 1
                continue
            except Exception:
                pass  # doesn't exist yet, proceed with copy

        src_blob_url = f"{src_account_url}/{src_container}/{blob.name}?{src_sas}"
        try:
            copy_result = dst_blob_client.start_copy_from_url(
                src_blob_url, metadata=blob.metadata
            )
            status = copy_result.get("copy_status", "pending")
            for _ in range(60):
                if status in ("success", "failed"):
                    break
                time.sleep(1)
                status = dst_blob_client.get_blob_properties().copy.status
            if status != "success":
                raise RuntimeError(f"copy status: {status}")
            logger.info(f"  COPIED: {blob.name} -> {dst_blob_name}")
            copied += 1
        except Exception as e:
            logger.error(f"  FAILED: {blob.name} -> {dst_blob_name} ({e})")
            failed += 1

    logger.info(f"symlink copy done. copied={copied} skipped={skipped} failed={failed}")
    return copied, skipped, failed


def copy_container_path(
    src_resource_group_name,
    src_storage_account_name,
    src_container,
    src_path,
    dst_container,
    dst_resource_group_name=None,
    dst_storage_account_name=None,
    dst_path=None,
    expires_in_days=1,
    overwrite=False,
    dry_run=False,
):
    """Copy src_container/src_path to dst_container/dst_path, preserving symlinks.

    dst_resource_group_name/dst_storage_account_name default to the source's, for the
    common case of copying within the same storage account.
    """
    dst_resource_group_name = dst_resource_group_name or src_resource_group_name
    dst_storage_account_name = dst_storage_account_name or src_storage_account_name
    dst_path = src_path if dst_path is None else dst_path

    src_sas = get_container_sas(
        src_resource_group_name, src_storage_account_name, src_container, "rl", expires_in_days
    )
    dst_sas = get_container_sas(
        dst_resource_group_name, dst_storage_account_name, dst_container, "acdlrw", expires_in_days
    )

    if dry_run:
        logger.info(
            f"[dry-run] would run azcopy data copy {src_storage_account_name}/{src_container}/{src_path} -> "
            f"{dst_storage_account_name}/{dst_container}/{dst_path}"
        )
    else:
        copy_blob_data(
            src_storage_account_name,
            src_container,
            src_path,
            src_sas,
            dst_storage_account_name,
            dst_container,
            dst_path,
            dst_sas,
            overwrite="true" if overwrite else "false",
        )

    copy_symlink_blobs(
        src_storage_account_name,
        src_container,
        src_path,
        src_sas,
        dst_storage_account_name,
        dst_container,
        dst_path,
        dst_sas,
        overwrite=overwrite,
        dry_run=dry_run,
    )


@click.command(
    help="Copy a folder from one blob container/path to another (optionally in a different storage account), preserving symlinks."
)
@click.option(
    "--src-resource-group-name",
    prompt="source resource group name",
    help="resource group containing the source storage account",
)
@click.option(
    "--src-storage-account-name",
    prompt="source storage account name",
    help="source storage account name",
)
@click.option("--src-container", prompt="source container", help="source container name")
@click.option(
    "--src-path",
    prompt="source path",
    help="source virtual directory path within the source container, e.g. benchmark_118",
)
@click.option(
    "--dst-resource-group-name",
    default=None,
    help="resource group containing the destination storage account. Defaults to --src-resource-group-name",
)
@click.option(
    "--dst-storage-account-name",
    default=None,
    help="destination storage account name. Defaults to --src-storage-account-name",
)
@click.option("--dst-container", prompt="destination container", help="destination container name")
@click.option(
    "--dst-path",
    default=None,
    help="destination virtual directory path. Defaults to --src-path",
)
@click.option(
    "--overwrite/--no-overwrite",
    default=False,
    help="overwrite existing blobs at the destination",
)
@click.option(
    "--dry-run",
    is_flag=True,
    default=False,
    help="preview the operation without copying anything",
)
@click.option(
    "--expires-in-days",
    default=1,
    show_default=True,
    type=int,
    help="SAS token lifetime in days",
)
@click.option(
    "--log-level",
    default="INFO",
    type=click.Choice(
        ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], case_sensitive=False
    ),
    show_default=True,
    help="The log level to use. Default is INFO",
)
def copy_container_path_cmd(
    src_resource_group_name,
    src_storage_account_name,
    src_container,
    src_path,
    dst_resource_group_name,
    dst_storage_account_name,
    dst_container,
    dst_path,
    overwrite,
    dry_run,
    expires_in_days,
    log_level,
):
    batch.setup_logging(log_level)
    setup_logging(log_level)
    copy_container_path(
        src_resource_group_name,
        src_storage_account_name,
        src_container,
        src_path,
        dst_container,
        dst_resource_group_name=dst_resource_group_name,
        dst_storage_account_name=dst_storage_account_name,
        dst_path=dst_path,
        expires_in_days=expires_in_days,
        overwrite=overwrite,
        dry_run=dry_run,
    )



if __name__ == "__main__":
    copy_container_path_cmd()
