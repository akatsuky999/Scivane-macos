"""HTTP 接口层。App 只和这一层对话。"""

from .app import create_app

__all__ = ["create_app"]
