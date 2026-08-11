"""
Offline unit tests for dmsbatch.commands.AzureBatch's use of the azure-batch v15.x SDK.

These build model objects and inspect the client/credential wiring without making any
network calls, so they run under the default `pytest -m "not integration"` selection.
"""
from unittest.mock import MagicMock

from azure.batch import BatchClient
from azure.batch import models as batchmodels
from azure.core.credentials import AzureNamedKeyCredential
from azure.identity import DefaultAzureCredential
import pytest

import dmsbatch


@pytest.fixture
def batch_client() -> dmsbatch.AzureBatch:
    return dmsbatch.commands.AzureBatch(
        "fakeaccount", "ZmFrZWtleQ==", "https://fakeaccount.eastus.batch.azure.com"
    )


def test_azure_batch_uses_v15_client_and_named_key_credential(batch_client):
    assert isinstance(batch_client.credentials, AzureNamedKeyCredential)
    assert isinstance(batch_client.batch_client, BatchClient)


def test_azure_batch_aad_auth_mode_uses_default_azure_credential():
    # UserSubscription-mode accounts (e.g. schismbatchscus2) disallow SharedKey auth entirely,
    # so no key is needed/used when auth_mode='aad'.
    client = dmsbatch.commands.AzureBatch(
        "fakeaccount",
        None,
        "https://fakeaccount.southcentralus.batch.azure.com",
        auth_mode="aad",
    )
    assert isinstance(client.credentials, DefaultAzureCredential)
    assert isinstance(client.batch_client, BatchClient)


def test_azure_batch_unknown_auth_mode_raises():
    with pytest.raises(ValueError):
        dmsbatch.commands.AzureBatch(
            "fakeaccount", "key", "https://fakeaccount.eastus.batch.azure.com", auth_mode="bogus"
        )


def test_mark_job_termination_on_task_completion_calls_update_job(batch_client):
    batch_client.batch_client = MagicMock()
    batch_client.mark_job_termination_on_task_completion("job1")
    args, kwargs = batch_client.batch_client.update_job.call_args
    assert kwargs["job_id"] == "job1"
    job_update = kwargs["job"]
    assert isinstance(job_update, batchmodels.BatchJobUpdateOptions)
    assert job_update.all_tasks_complete_mode == batchmodels.BatchAllTasksCompleteMode.TERMINATE_JOB


def test_create_task_builds_batch_task_create_options(batch_client):
    task = batch_client.create_task("t1", "echo hi")
    assert isinstance(task, batchmodels.BatchTaskCreateOptions)
    assert task.id == "t1"
    assert task.command_line == "echo hi"


def test_create_output_file_spec_builds_output_file(batch_client):
    spec = batch_client.create_output_file_spec(
        "*.txt", "https://fake.blob.core.windows.net/c?sas"
    )
    assert isinstance(spec, batchmodels.OutputFile)
    assert spec.upload_options["uploadCondition"] == "taskcompletion"


def test_create_prep_task_builds_batch_job_preparation_task(batch_client):
    prep = batch_client.create_prep_task("prep", ["echo hi"], ostype="linux")
    assert isinstance(prep, batchmodels.BatchJobPreparationTask)
    assert prep.user_identity.auto_user.scope == batchmodels.AutoUserScope.POOL
    assert prep.user_identity.auto_user.elevation_level == batchmodels.ElevationLevel.ADMIN
