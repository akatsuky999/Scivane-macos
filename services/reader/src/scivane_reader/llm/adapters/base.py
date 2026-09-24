"""协议适配的公共契约与线缆解析。

**分工**：传输机制（httpx、重试、超时、取消、SSE 分帧）集中在 registry.py，
只写一遍；适配器只负责翻译 —— 把统一请求译成厂商的 JSON 形状，把厂商的
流式事件译回统一的 StreamChunk。

这个切分把协议无关的机制与各厂商的格式翻译分开：一处机制、多处翻译，
新增厂商时不必再碰一行网络代码。
"""

from __future__ import annotations

import codecs
import json
from abc import ABC, abstractmethod
from collections.abc import AsyncIterator, Iterable, Iterator
from dataclasses import dataclass

from ..cache import CacheCapability
from ..errors import classify_status
from ..types import CallRequest, Finish, StreamChunk


@dataclass(frozen=True)
class SseEvent:
    """一个 SSE 帧。`event` 对不带事件名的协议（OpenAI/Gemini）是空串。"""

    event: str
    data: str


def iter_sse_frames(text: str) -> Iterator[SseEvent]:
    """把已经切好的一段文本解析成 SSE 帧。

    只处理帧内解析；跨网络分片的缓冲由 `SseDecoder` 负责。
    """
    for block in text.split("\n\n"):
        if not block.strip():
            continue
        event = ""
        data_lines: list[str] = []
        for line in block.split("\n"):
            if line.startswith("event:"):
                event = line[6:].strip()
            elif line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
            # 以 ":" 开头的是注释（心跳），忽略
        if data_lines:
            yield SseEvent(event=event, data="\n".join(data_lines))


class SseDecoder:
    """把网络字节流增量解析成 SSE 帧。

    两处必须做对，否则会出现「偶发乱码」这类极难复现的 bug：

    1. **UTF-8 增量解码** —— 网络分片会把一个多字节字符劈成两半。用
       `bytes.decode()` 逐片解码必炸，所以这里用增量解码器把半个字符
       留到下一片。中文论文里这种情况极其常见。
    2. **帧边界缓冲** —— 一帧可能横跨多个分片，切不完整就留在缓冲里等下一片。
       （这正是 Scivane 服务端 SSE 客户端 OCRClient.swift 里同样的做法。）
    """

    def __init__(self) -> None:
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self._buffer = ""

    def feed(self, chunk: bytes) -> Iterator[SseEvent]:
        self._buffer += self._decoder.decode(chunk)
        while "\n\n" in self._buffer:
            head, self._buffer = self._buffer.split("\n\n", 1)
            yield from iter_sse_frames(head + "\n\n")

    def flush(self) -> Iterator[SseEvent]:
        """流结束时把缓冲里剩下的半帧交出去。"""
        self._buffer += self._decoder.decode(b"", final=True)
        remainder, self._buffer = self._buffer, ""
        if remainder.strip():
            yield from iter_sse_frames(remainder)


class StreamTranslator(ABC):
    """一次流的翻译器。有状态，每条流新建一个。

    做成对象而不是纯函数，是因为几乎所有协议都需要跨事件的状态：
    Anthropic 要配对 content_block_start / delta / stop，各家都要累计用量。
    """

    @abstractmethod
    def feed(self, event: SseEvent) -> Iterable[StreamChunk]:
        """吃进一个厂商事件，吐出零或多个统一分片。

        **不要在这里产出 Finish** —— 终态统一由 `finish()` 给出，
        保证「每个流恰好一个 Finish」这条不变式只有一个出口。
        """

    @abstractmethod
    def finish(self) -> Finish:
        """流正常结束时的终态。由适配器根据已收到的事件判断 stop / length。"""


class ProtocolAdapter(ABC):
    """一套厂商协议。"""

    #: 协议标识，写进配置里的 `protocol` 字段。
    name: str
    #: 这套协议支持哪种 prompt 缓存。
    cache_capability: CacheCapability
    #: 用户没填 base_url 时的默认值。
    default_base_url: str

    @abstractmethod
    def endpoint(self, base_url: str, request: CallRequest) -> str:
        """这次请求要打的完整 URL。Gemini 把模型名放在路径里，所以要拿到 request。"""

    @abstractmethod
    def headers(self, api_key: str) -> dict[str, str]:
        """鉴权与协议头。"""

    @abstractmethod
    def payload(self, request: CallRequest) -> dict[str, object]:
        """请求体。缓存断点也在这里落地。"""

    @abstractmethod
    def translator(self) -> StreamTranslator:
        """为一条新的流创建翻译器。"""

    def classify(self, status: int, body: str) -> str:
        """把厂商错误映射成稳定失败码。

        默认走通用的状态码规则；某个厂商有更精确的结构化错误信息时，
        在自己的适配器里覆盖这个方法，先做精确判断再退回 super()。
        """
        return classify_status(status, body)

    @staticmethod
    def error_detail(body: str) -> str:
        """从厂商错误体里取出用于判别的文本。

        三家的错误体形状不同，但都把有用信息藏在嵌套的 message 字段里。
        取不出来就退回原文 —— 分类逻辑对多余文本是宽容的。
        """
        try:
            parsed = json.loads(body)
        except (ValueError, TypeError):
            return body
        if not isinstance(parsed, dict):
            return body
        error = parsed.get("error")
        if isinstance(error, dict):
            parts = [
                str(error.get(key, ""))
                for key in ("message", "code", "type", "status")
                if error.get(key)
            ]
            if parts:
                return " ".join(parts)
        if isinstance(error, str):
            return error
        message = parsed.get("message")
        if isinstance(message, str):
            return message
        return body


async def aiter_sse(
    byte_stream: AsyncIterator[bytes],
) -> AsyncIterator[SseEvent]:
    """把字节流转成 SSE 帧流。"""
    decoder = SseDecoder()
    async for chunk in byte_stream:
        for event in decoder.feed(chunk):
            yield event
    for event in decoder.flush():
        yield event
