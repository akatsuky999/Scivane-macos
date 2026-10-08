"""Shared adapter contract and SSE parsing.

Transport lives in registry.py; adapters only translate requests and stream events.
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
    """One SSE frame; `event` is empty for protocols without event names (OpenAI, Gemini)."""

    event: str
    data: str


def iter_sse_frames(text: str) -> Iterator[SseEvent]:
    """Parse already-split text into frames; buffering across chunks is SseDecoder's job."""
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
            # lines starting with ':' are comments (heartbeats)
        if data_lines:
            yield SseEvent(event=event, data="\n".join(data_lines))


class SseDecoder:
    """Incremental SSE decoding from network bytes.

    UTF-8 is decoded incrementally because chunks split multi-byte characters (constantly, with
    Chinese text), and partial frames are buffered across chunks.
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
        """Flush the trailing partial frame at the end of the stream."""
        self._buffer += self._decoder.decode(b"", final=True)
        remainder, self._buffer = self._buffer, ""
        if remainder.strip():
            yield from iter_sse_frames(remainder)


class StreamTranslator(ABC):
    """Translator for one stream. Stateful: Anthropic pairs block start/delta/stop and every
    protocol accumulates usage.
    """

    @abstractmethod
    def feed(self, event: SseEvent) -> Iterable[StreamChunk]:
        """Translate one vendor event into zero or more chunks.

        Never yield Finish here; finish() is the single exit.
        """

    @abstractmethod
    def finish(self) -> Finish:
        """Terminal chunk for a normal end (stop or length)."""


class ProtocolAdapter(ABC):
    #: value of `protocol` in the provider settings
    name: str
    cache_capability: CacheCapability
    default_base_url: str

    @abstractmethod
    def endpoint(self, base_url: str, request: CallRequest) -> str:
        """Full URL for this request (Gemini puts the model in the path)."""

    @abstractmethod
    def headers(self, api_key: str) -> dict[str, str]:
        """Auth and protocol headers."""

    @abstractmethod
    def payload(self, request: CallRequest) -> dict[str, object]:
        """Request body, including cache markers."""

    @abstractmethod
    def translator(self) -> StreamTranslator:
        """A translator for a new stream."""

    def model_info_url(self, base_url: str, model: str) -> str | None:
        """Where to ask for the model's context window, or None if the protocol can't say.

        Ask the endpoint rather than a local table: windows differ by gateway and '-latest'
        aliases change.
        """
        return None

    def context_window_from(self, payload: object, model: str) -> int | None:
        """Read the window from the model_info_url response, or None."""
        return None

    def classify(self, status: int, body: str) -> str:
        """Map a vendor error to a stable code. Override for structured errors, then fall back to super()."""
        return classify_status(status, body)

    @staticmethod
    def error_detail(body: str) -> str:
        """Text to classify from a vendor error body; falls back to the raw body."""
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
    decoder = SseDecoder()
    async for chunk in byte_stream:
        for event in decoder.feed(chunk):
            yield event
    for event in decoder.flush():
        yield event
