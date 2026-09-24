"""论文标题的提取。

两条路径，精度不同：

- **快猜**（建项目那一刻）：读 PDF 元数据，不行就看首页最大字号的文字。
  毫秒级，不需要模型，所以点完「构建项目」立刻就有名字。
- **精确化**（OCR 完成后）：取 Markdown 的第一个一级标题。版面模型已经
  判定过「哪块是标题」，比按字号猜可靠得多。

后来者只有在**更可靠**时才允许覆盖先来者，见 `better_than` —— 否则一次
失败的 OCR 会把已经猜对的名字改成一句正文。
"""

from __future__ import annotations

import re
from pathlib import Path

from .model import TitleSource

#: 精度序。数值大的可以覆盖数值小的。
_RANK: dict[TitleSource, int] = {
    # 空项目没起名字时的占位名。**排在文件名之下** —— 它不是谁给的名字，
    # 所以连"文件名去扩展名"这种粗糙的猜测都比它强。
    "placeholder": -1,
    "filename": 0,
    "pdf-metadata": 1,
    "pdf-heading": 2,
    "markdown-heading": 3,
    "manual": 4,   # 用户改过的名字，任何自动提取都不许覆盖
}

#: 一望即知不是论文标题的元数据。很多 PDF 的 Title 字段是转换工具留下的垃圾。
_JUNK_TITLE = re.compile(
    r"^\s*$"
    r"|^(microsoft word|powerpoint presentation|untitled|document\d*|print)\b"
    r"|\.(docx?|pptx?|tex|pdf|indd)\s*$",
    re.IGNORECASE,
)

MAX_TITLE_CHARS = 300


#: 认不出来的来源排在所有已知来源之下 —— 包括 placeholder。
#: 不这么定的话，一个陌生的来源会和 placeholder 打平，
#: 于是「占位名永远改不掉」这种安静的坏行为就出现了。
_UNKNOWN_RANK = -99


def better_than(candidate: TitleSource, current: TitleSource) -> bool:
    """`candidate` 是否比 `current` 更可靠。"""
    return _RANK.get(candidate, _UNKNOWN_RANK) > _RANK.get(current, _UNKNOWN_RANK)


def clean(raw: str) -> str:
    """规范化候选标题。

    论文标题常常在 PDF 里被排成多行，取出来带一堆换行与连字符断词。
    """
    text = raw.replace("\r", "\n")
    # 行尾连字符断词：把 "Atten-\ntion" 接回 "Attention"
    text = re.sub(r"(\w)-\n(\w)", r"\1\2", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = text.strip(" \t\n·—-–_*#")
    return text[:MAX_TITLE_CHARS]


def is_plausible(text: str) -> bool:
    """看起来像不像一个标题。

    太短的多半是页眉页脚残片，太长的多半是把摘要整段吞了进来。
    """
    stripped = clean(text)
    if len(stripped) < 4 or len(stripped) > MAX_TITLE_CHARS:
        return False
    if _JUNK_TITLE.search(stripped):
        return False
    # 全是数字或符号的不是标题（页码、DOI 行）
    return any(ch.isalpha() or "一" <= ch <= "鿿" for ch in stripped)


def from_filename(path: Path) -> tuple[str, TitleSource]:
    """兜底：文件名去掉扩展名。永远有结果，所以它是最后一道。"""
    return clean(path.stem) or path.name, "filename"


def from_pdf(path: Path) -> tuple[str, TitleSource] | None:
    """快猜：PDF 元数据，不行就看首页最大字号的文字。

    整个过程不碰模型，毫秒级完成 —— 这是「点完按钮立刻有名字」的前提。
    读不出来返回 None，由调用方退到文件名。
    """
    try:
        import pymupdf
    except ImportError:
        return None

    try:
        with pymupdf.open(path) as doc:
            meta = doc.metadata or {}
            candidate = clean(str(meta.get("title") or ""))
            if is_plausible(candidate):
                return candidate, "pdf-metadata"

            if doc.page_count == 0:
                return None
            heading = _largest_heading(doc[0])
            if heading and is_plausible(heading):
                return clean(heading), "pdf-heading"
    except Exception:
        # 加密、损坏、非 PDF —— 都不该让建项目这件事失败
        return None
    return None


def _largest_heading(page) -> str | None:
    """首页上字号最大的那段文字。

    论文的排版惯例是标题字号最大且靠上。只看上半页，避免把正文里某个
    大字号的图注或章节标题当成论文标题。
    """
    try:
        blocks = page.get_text("dict")["blocks"]
    except Exception:
        return None

    height = page.rect.height or 1
    best_size = 0.0
    best_lines: list[tuple[float, str]] = []

    for block in blocks:
        for line in block.get("lines", []):
            spans = line.get("spans", [])
            if not spans:
                continue
            top = line.get("bbox", [0, 0, 0, 0])[1]
            if top > height * 0.5:      # 只看上半页
                continue
            size = max(float(s.get("size", 0)) for s in spans)
            text = "".join(s.get("text", "") for s in spans)
            if not text.strip():
                continue
            if size > best_size + 0.5:
                best_size = size
                best_lines = [(top, text)]
            elif abs(size - best_size) <= 0.5:
                # 同一字号的相邻行属于同一个标题，要接起来
                best_lines.append((top, text))

    if not best_lines:
        return None
    best_lines.sort(key=lambda item: item[0])
    return "\n".join(text for _, text in best_lines)


_MD_HEADING = re.compile(r"^\s{0,3}#\s+(.+?)\s*#*\s*$", re.MULTILINE)


def from_markdown(markdown: str) -> tuple[str, TitleSource] | None:
    """精确化：Markdown 的第一个一级标题。

    版面模型已经判定过「这一块是标题」，比按字号猜可靠。
    """
    match = _MD_HEADING.search(markdown)
    if match is None:
        return None
    candidate = clean(match.group(1))
    if not is_plausible(candidate):
        return None
    return candidate, "markdown-heading"
