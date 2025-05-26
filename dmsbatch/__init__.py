try:
    from ._version import __version__
except ImportError:
    __version__ = "0.0.0"

from .commands import create_batch_client, create_blob_client, query_yes_no
from .commands import AzureBatch, AzureBlob
