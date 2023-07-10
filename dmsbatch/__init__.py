from ._version import get_versions
__version__ = get_versions()['version']
del get_versions
#
from .commands import create_batch_client, create_blob_client, query_yes_no
from .commands import AzureBatch, AzureBlob

from . import _version
__version__ = _version.get_versions()['version']
