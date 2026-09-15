from pathlib import Path

import pytest

from dmsbatch.template_resources import TemplateResources


@pytest.fixture
def external_template(tmp_path):
    jobs_dir = tmp_path / "batch" / "jobs"
    template_dir = tmp_path / "batch" / "templates" / "custom_gpu"
    jobs_dir.mkdir(parents=True)
    template_dir.mkdir(parents=True)

    config_file = jobs_dir / "train.yml"
    config_file.write_text("template_name: custom_gpu\n", encoding="utf-8")
    (template_dir / "default_config.yml").write_text(
        "application_command_template: application_command_template.sh\n",
        encoding="utf-8",
    )
    (template_dir / "application_command_template.sh").write_text(
        "#!/bin/bash\n{command}\n",
        encoding="utf-8",
    )
    (template_dir / "coordination_command_template.sh").write_text(
        "#!/bin/bash\n{mpi_command}\n",
        encoding="utf-8",
    )
    (template_dir / "job_start_command_template.sh").write_text(
        "#!/bin/bash\necho ready\n",
        encoding="utf-8",
    )
    (template_dir / "pool.bicep").write_text(
        "targetScope = 'resourceGroup'\n",
        encoding="utf-8",
    )
    (template_dir / "pool.parameters.json").write_text(
        '{"parameters": {}}\n',
        encoding="utf-8",
    )
    (template_dir / "autoscale_formula.txt").write_text(
        "$TargetDedicatedNodes = 0\n",
        encoding="utf-8",
    )
    return config_file, template_dir


def test_external_template_dir_is_relative_to_config(external_template, monkeypatch, tmp_path):
    config_file, template_dir = external_template
    monkeypatch.chdir(tmp_path)

    resources = TemplateResources.from_config(
        {
            "template_name": "custom_gpu",
            "template_dir": "../templates/custom_gpu",
        },
        config_file,
    )

    assert resources.template_dir == template_dir.resolve()
    assert "application_command_template" in resources.read_text("default_config.yml")
    assert resources.read_text(
        "templates/custom_gpu/application_command_template.sh"
    ).startswith("#!/bin/bash")
    with resources.as_path("pool.bicep") as pool_path:
        assert pool_path == template_dir / "pool.bicep"


def test_packaged_template_resources_still_resolve():
    resources = TemplateResources("dvsm_container")

    assert "pool_bicep_resource" in resources.read_text("default_config.yml")
    with resources.as_path("templates/dvsm_container/pool.bicep") as pool_path:
        assert Path(pool_path).is_file()


def test_external_missing_script_is_not_treated_as_inline_command(external_template):
    config_file, template_dir = external_template
    resources = TemplateResources.from_config(
        {
            "template_name": "custom_gpu",
            "template_dir": "../templates/custom_gpu",
        },
        config_file,
    )

    with pytest.raises(FileNotFoundError, match="missing.sh.*custom_gpu"):
        resources.load_command("missing.sh")

    assert resources.load_command("echo ready") == "echo ready"
    assert resources.load_command("bash missing.sh") == "bash missing.sh"
    assert resources.load_command("echo first\necho second") == "echo first\necho second"
    assert resources.template_dir == template_dir.resolve()


def test_external_template_config_validation(external_template):
    config_file, template_dir = external_template
    resources = TemplateResources.from_config(
        {
            "template_name": "custom_gpu",
            "template_dir": "../templates/custom_gpu",
        },
        config_file,
    )
    config = {
        "application_command_template": "application_command_template.sh",
        "coordination_command_template": "coordination_command_template.sh",
        "job_start_command_template": "echo inline setup",
        "pool_bicep_resource": "pool.bicep",
        "pool_parameters_resource": "pool.parameters.json",
        "autoscale_formula": "autoscale_formula.txt",
    }

    resources.validate_config(config)
    config["autoscale_formula"] = "missing_autoscale_formula.txt"
    with pytest.raises(FileNotFoundError, match="autoscale_formula.txt"):
        resources.validate_config(config)


def test_template_resource_cannot_escape_external_directory(external_template):
    config_file, _ = external_template
    resources = TemplateResources.from_config(
        {
            "template_name": "custom_gpu",
            "template_dir": "../templates/custom_gpu",
        },
        config_file,
    )

    with pytest.raises(ValueError, match="Invalid resource path"):
        resources.read_text("../outside.sh")