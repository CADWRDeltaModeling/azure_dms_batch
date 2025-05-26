"""
A minimal setup.py file to maintain compatibility with older tools.
Most of the configuration is in pyproject.toml
"""

from setuptools import setup

setup(
    use_scm_version=True,
    setup_requires=["setuptools_scm"],
)
