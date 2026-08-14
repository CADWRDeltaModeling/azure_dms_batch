import json
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
BICEP_DIR = REPO_ROOT / "bicep"
SETUP_SCRIPT = BICEP_DIR / "setup_schism_alert.sh"
WORKFLOW_FILES = (
    "schism_alert_workflow.json",
    "schism_terminate_workflow.json",
)


def load_workflow(filename):
    with (BICEP_DIR / filename).open(encoding="utf-8") as workflow_file:
        return json.load(workflow_file)


@pytest.mark.parametrize("filename", WORKFLOW_FILES)
def test_workflow_fetches_linked_rows_for_fired_alerts(filename):
    actions = load_workflow(filename)["actions"]

    initialize = actions["Initialize_alert_rows"]
    variable = initialize["inputs"]["variables"][0]
    assert variable["name"] == "alertRows"
    assert "coalesce(" in variable["value"]

    fetch = actions["Fetch_linked_alert_rows"]
    assert fetch["expression"]["and"][0]["equals"][1] == "Fired"
    assert fetch["actions"]["Get_linked_alert_rows"]["inputs"]["authentication"] == {
        "type": "ManagedServiceIdentity",
        "audience": "https://api.applicationinsights.io",
    }

    select = fetch["actions"]["Select_linked_alert_rows"]["inputs"]["select"]
    assert list(select) == [
        "host",
        "CreatedBy",
        "StuckAtDays",
        "StuckReason",
        "CurrentSchismTime",
        "batchAccount",
        "batchRegion",
    ]
    assert actions["For_each_stuck_host"]["foreach"] == "@variables('alertRows')"


@pytest.mark.parametrize("filename", WORKFLOW_FILES)
def test_workflow_surfaces_processing_failures(filename):
    actions = load_workflow(filename)["actions"]

    assert actions["Respond_OK"]["runAfter"]["For_each_stuck_host"] == ["Succeeded"]
    assert actions["Respond_fetch_failed"]["inputs"]["statusCode"] == 500
    assert actions["Respond_processing_failed"]["inputs"]["statusCode"] == 500


def test_termination_email_requires_successful_batch_request():
    actions = load_workflow("schism_terminate_workflow.json")["actions"]
    job_actions = (
        actions["For_each_stuck_host"]["actions"]["Batch_account_known"]["actions"]
        ["Job_found"]["actions"]
    )

    assert job_actions["Terminate_job"]["inputs"]["headers"]["Content-Type"] == (
        "application/json; odata=minimalmetadata"
    )
    assert job_actions["Log_termination_result"]["runAfter"]["Terminate_job"] == ["Succeeded"]
    assert "statusCode'], 200" in job_actions["Log_termination_result"]["inputs"]["success"]
    assert "statusCode'], 202" in job_actions["Log_termination_result"]["inputs"]["success"]


@pytest.mark.parametrize("filename", WORKFLOW_FILES)
def test_null_metadata_is_treated_as_missing(filename):
    actions = load_workflow(filename)["actions"]
    host_actions = actions["For_each_stuck_host"]["actions"]
    batch_expression = host_actions["Batch_account_known"]["expression"]

    assert "@empty(items('For_each_stuck_host')?['batchAccount'])" in str(batch_expression)
    assert "@empty(items('For_each_stuck_host')?['batchRegion'])" in str(batch_expression)


def test_alert_rules_are_split_by_host():
    setup_script = SETUP_SCRIPT.read_text(encoding="utf-8")
    host_dimension = '"name": "host"'

    assert setup_script.count(host_dimension) == 2