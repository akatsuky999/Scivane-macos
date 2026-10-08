"""Run the orchestration API directly, without llama-server."""

from __future__ import annotations

import logging

import uvicorn

from . import config


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)-7s %(name)s  %(message)s",
    )
    uvicorn.run(
        "scivane_reader.api.app:app",
        host=config.API_HOST,
        port=config.API_PORT,
        log_level="info",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
