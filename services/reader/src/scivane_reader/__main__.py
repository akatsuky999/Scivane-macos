"""python -m scivane_reader —— 直接把服务跑起来。

正常路径是 App 调 scripts/start_backend.sh，那个脚本会先拉 llama-server。
单独跑这个只起编排层，适合调接口。
"""

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
