"""HTTP layer; the only interface the app talks to."""

from .app import create_app

__all__ = ["create_app"]
