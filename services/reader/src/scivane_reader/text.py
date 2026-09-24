"""Markdown 的文本处理小工具。"""

from __future__ import annotations

import re

_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_HTML_TAG = re.compile(r"<[^>]+>")
_HEADING = re.compile(r"^#{1,6}\s*", re.MULTILINE)
_EMPHASIS = re.compile(r"(\*\*|__|\*|_|`)")
_BLANK_RUN = re.compile(r"\n{3,}")


def plain_text(markdown: str) -> str:
    """给「复制纯文本」用：剥掉 Markdown 记号，保留段落结构。"""
    text = _IMAGE.sub("", markdown)          # 图片整个去掉
    text = _LINK.sub(r"\1", text)            # 链接保留文字
    text = _HTML_TAG.sub("", text)           # 内嵌 HTML
    text = _HEADING.sub("", text)            # 标题井号
    text = _EMPHASIS.sub("", text)           # 强调与行内码
    text = _BLANK_RUN.sub("\n\n", text)
    return text.strip()
