"""文档解析：版面分析 + VLM 识别。

- `documents` 负责纸面上的事：数页、拆页、抠图落盘
- `pipeline` 负责模型的事：PaddleOCR-VL 封装与逐页编排
"""

from .documents import PageResult, page_count
from .pipeline import parse_document, warmup

__all__ = ["PageResult", "page_count", "parse_document", "warmup"]
