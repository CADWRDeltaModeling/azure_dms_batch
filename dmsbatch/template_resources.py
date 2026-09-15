from contextlib import contextmanager
from importlib.resources import as_file, files
from pathlib import Path, PurePosixPath


class TemplateResources:
    COMMAND_FIELDS = (
        "application_command_template",
        "coordination_command_template",
        "job_start_command_template",
    )
    FILE_FIELDS = (
        "pool_bicep_resource",
        "pool_parameters_resource",
        "autoscale_formula",
    )

    def __init__(self, template_name, template_dir=None):
        self.template_name = template_name
        self.template_dir = Path(template_dir).resolve() if template_dir else None

    @classmethod
    def from_config(cls, config_dict, config_file=None):
        template_dir = config_dict.get("template_dir")
        if template_dir and config_file and not Path(template_dir).is_absolute():
            template_dir = Path(config_file).resolve().parent / template_dir
        return cls(config_dict["template_name"], template_dir)

    def _relative_name(self, resource_name):
        parts = list(PurePosixPath(str(resource_name).replace("\\", "/")).parts)
        if parts[:1] == ["dmsbatch"]:
            parts = parts[1:]
        if parts[:2] == ["templates", self.template_name]:
            parts = parts[2:]
        if not parts or any(part in ("", ".", "..") for part in parts):
            raise ValueError(
                f"Invalid resource path for template '{self.template_name}': "
                f"{resource_name}"
            )
        return PurePosixPath(*parts)

    def resource(self, resource_name):
        relative_name = self._relative_name(resource_name)
        if self.template_dir:
            resource = self.template_dir.joinpath(*relative_name.parts).resolve()
            if self.template_dir not in resource.parents:
                raise ValueError(
                    f"Template resource escapes template_dir '{self.template_dir}': "
                    f"{resource_name}"
                )
            return resource

        resource = files("dmsbatch").joinpath("templates", self.template_name)
        return resource.joinpath(*relative_name.parts)

    def _not_found(self, resource_name):
        source = self.template_dir or f"dmsbatch/templates/{self.template_name}"
        return FileNotFoundError(
            f"Template resource '{resource_name}' was not found for template "
            f"'{self.template_name}' in '{source}'"
        )

    def read_text(self, resource_name):
        resource = self.resource(resource_name)
        try:
            if not resource.is_file():
                raise self._not_found(resource_name)
            return resource.read_text(encoding="utf-8")
        except (FileNotFoundError, AttributeError) as exc:
            raise self._not_found(resource_name) from exc

    @contextmanager
    def as_path(self, resource_name):
        resource = self.resource(resource_name)
        try:
            if not resource.is_file():
                raise self._not_found(resource_name)
            if self.template_dir:
                yield resource
            else:
                with as_file(resource) as resource_path:
                    yield resource_path
        except (FileNotFoundError, AttributeError) as exc:
            raise self._not_found(resource_name) from exc

    def load_command(self, value):
        try:
            return self.read_text(value)
        except FileNotFoundError:
            if self.template_dir and self._looks_like_resource(value):
                raise
            return value

    def validate_config(self, config_dict):
        if not self.template_dir:
            return
        for field in self.COMMAND_FIELDS:
            value = config_dict[field].replace("{template_name}", self.template_name)
            self.load_command(value)
        for field in self.FILE_FIELDS:
            value = config_dict[field].replace("{template_name}", self.template_name)
            self.read_text(value)

    @staticmethod
    def _looks_like_resource(value):
        if not isinstance(value, str) or any(character.isspace() for character in value):
            return False
        path = PurePosixPath(value.replace("\\", "/"))
        return path.suffix.lower() in {".bat", ".cmd", ".ps1", ".sh"}