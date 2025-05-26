# Migration from setup.py to pyproject.toml

This project has been migrated from a classic `setup.py` configuration to a modern `pyproject.toml` configuration. Here are the key changes and how to work with the new setup:

## Package Structure

- `pyproject.toml`: Main configuration file for building, dependencies, and metadata
- `setup.py`: Minimal file that provides compatibility with older tools
- Automated versioning using setuptools_scm based on git tags

## Building and Development

For development:
```bash
pip install -e .
```

For building:
```bash
pip install build
python -m build
```

## Conda Build

The conda recipe has been updated to work with the new pyproject.toml structure. You can build a conda package using:

```bash
conda build conda.recipe
```

## Version Management with setuptools_scm

The project now uses setuptools_scm for automatic version determination from git tags:

1. Tag your release: `git tag 2025.05.23`
2. The version will automatically be determined from the git metadata
3. Format: `{tag}.post{commits}+{hash}.d{date}` (e.g., `2025.05.23.post2+g7250da5.d20250526`)

## Dependencies

All dependencies are now specified in `pyproject.toml`. Make sure to keep both the pyproject.toml and conda.recipe/meta.yaml files in sync when adding new dependencies.

## CI/CD with GitHub Actions

The GitHub workflow has been updated to work with setuptools_scm:

1. It checks out the complete git history with `fetch-depth: 0` to ensure setuptools_scm has access to all tags
2. It sets the `SETUPTOOLS_SCM_PRETEND_VERSION` environment variable to ensure consistent versioning
3. The version is extracted from the git tag and used for both conda and PyPI (when enabled) builds

When a new version is tagged and pushed to GitHub, the workflow will automatically:
- Build a conda package with the correct version
- Upload it to the specified Anaconda channel
