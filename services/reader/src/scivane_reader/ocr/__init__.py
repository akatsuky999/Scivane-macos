"""Document parsing: layout analysis plus VLM recognition.

documents handles files and pages; pipeline handles the model.
"""

from .documents import PageResult, page_count
from .pipeline import parse_document, warmup

__all__ = ["PageResult", "page_count", "parse_document", "warmup"]
