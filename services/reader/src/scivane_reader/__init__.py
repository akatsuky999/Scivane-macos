"""Scivane 阅读代理的服务端。

当前只有文档解析（OCR）一条链路。后续的检索、问答、批注等能力
作为 `scivane_reader` 下的同级子包加入，共用 config / jobs / api 三个底座。
"""

__version__ = "0.1.0"
