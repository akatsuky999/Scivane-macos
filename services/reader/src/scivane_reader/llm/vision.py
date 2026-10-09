"""Can a model see images? Show it a random code and check that it reads it back.

Model lists rarely say whether a model takes images, and some gateways drop image parts
silently: the model then answers from the text alone, and a transcription comes back invented.
A behavioural check catches both. Pure stdlib (a 5x7 bitmap font and a PNG encoder), so the
model layer needs no imaging library.
"""

from __future__ import annotations

import base64
import random
import re
import struct
import zlib
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass

from ..i18n import ui
from .errors import INVALID_ARGS, NO_VISION, UNKNOWN, LlmError, LlmFailure
from .types import CallRequest, Finish, ImageBlock, Message, StreamChunk, TextBlock, TextDelta

__all__ = ["ALPHABET", "PROMPT", "VisionCheck", "challenge", "render", "matches", "probe"]

#: Glyphs no model confuses with one another: no 0/O, 1/I, 2/Z, 5/S, 8/B.
ALPHABET = "ACDEFHJKLMNPRTUVWXY34679"
CODE_LENGTH = 5
#: Model-facing, so English and fixed.
PROMPT = "Read the characters in this image. Reply with those characters only."
CONTROL_PROMPT = "Reply with the word OK."

_GLYPHS = {
    "A": (".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"),
    "C": (".####", "#....", "#....", "#....", "#....", "#....", ".####"),
    "D": ("####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."),
    "E": ("#####", "#....", "#....", "####.", "#....", "#....", "#####"),
    "F": ("#####", "#....", "#....", "####.", "#....", "#....", "#...."),
    "H": ("#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"),
    "J": ("..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."),
    "K": ("#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"),
    "L": ("#....", "#....", "#....", "#....", "#....", "#....", "#####"),
    "M": ("#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"),
    "N": ("#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"),
    "P": ("####.", "#...#", "#...#", "####.", "#....", "#....", "#...."),
    "R": ("####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"),
    "T": ("#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."),
    "U": ("#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
    "V": ("#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."),
    "W": ("#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"),
    "X": ("#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"),
    "Y": ("#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."),
    "3": ("####.", "....#", "....#", ".###.", "....#", "....#", "####."),
    "4": ("...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."),
    "6": (".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."),
    "7": ("#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."),
    "9": (".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."),
}

#: pixels per font dot; large enough that downscaling by any provider keeps it legible
_SCALE = 12
_PAD = 24
_GAP = 2


def challenge(rng: random.Random | None = None) -> str:
    source = rng if rng is not None else random.SystemRandom()
    return "".join(source.choice(ALPHABET) for _ in range(CODE_LENGTH))


def render(code: str) -> bytes:
    """The code as a black-on-white PNG. RGB like every real image this app sends (screenshots,
    page renders): the probe should take the same decoding path, not a greyscale special case.
    """
    columns = len(code) * 5 + max(0, len(code) - 1) * _GAP
    width = columns * _SCALE + 2 * _PAD
    height = 7 * _SCALE + 2 * _PAD
    rows = [bytearray(b"\xff" * (width * 3)) for _ in range(height)]
    for position, char in enumerate(code):
        glyph = _GLYPHS[char]
        left = _PAD + position * (5 + _GAP) * _SCALE
        for y, line in enumerate(glyph):
            for x, dot in enumerate(line):
                if dot != "#":
                    continue
                for dy in range(_SCALE):
                    row = rows[_PAD + y * _SCALE + dy]
                    start = (left + x * _SCALE) * 3
                    row[start:start + _SCALE * 3] = b"\x00" * (_SCALE * 3)
    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return _png(width, height, raw)


def _png(width: int, height: int, raw: bytes) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def matches(answer: str, code: str) -> bool:
    """Read correctly, tolerating one misread glyph. A model that never saw the image can't get
    four of five random characters in order.
    """
    cleaned = re.sub(r"[^A-Z0-9]", "", answer.upper())
    if code in cleaned:
        return True
    if not cleaned or len(cleaned) > 4 * len(code):
        return False
    return _common(cleaned, code) >= len(code) - 1


def _common(a: str, b: str) -> int:
    """Longest common subsequence length."""
    previous = [0] * (len(b) + 1)
    for char in a:
        current = [0]
        for j, other in enumerate(b):
            current.append(previous[j] + 1 if char == other else max(previous[j + 1], current[j]))
        previous = current
    return previous[-1]


@dataclass(frozen=True)
class VisionCheck:
    """supported is None when the check couldn't run (no key, out of quota, offline); `code`
    then says why. NO_VISION accompanies a definite no.
    """

    supported: bool | None
    code: str | None = None
    message: str = ""


Stream = Callable[[CallRequest], AsyncIterator[StreamChunk]]


async def probe(stream: Stream, model: str, *, rng: random.Random | None = None) -> VisionCheck:
    """Ask with an image; when the request is rejected as malformed, ask once without one to tell
    "can't take images" from a card that can't answer anything. A wrong reading is confirmed with
    a fresh code before it counts as blind: one misread must not shut images off for days, while
    a model that never saw the image can't read two random codes.
    """
    code = challenge(rng)
    answer, failure = await _collect(stream, _request(model, code))
    if failure is None and not matches(answer, code):
        code = challenge(rng)
        answer, failure = await _collect(stream, _request(model, code))
        if failure is None and not matches(answer, code):
            return VisionCheck(False, NO_VISION, _blind())
    if failure is None:
        return VisionCheck(True)
    if failure.code == NO_VISION:
        return VisionCheck(False, NO_VISION, failure.message)
    if failure.code in (INVALID_ARGS, UNKNOWN):
        control = CallRequest(
            model=model, messages=(Message.text("user", CONTROL_PROMPT),), purpose="background")
        _, control_failure = await _collect(stream, control)
        if control_failure is None:
            return VisionCheck(False, NO_VISION, failure.message or _blind())
        return VisionCheck(None, control_failure.code, control_failure.message)
    return VisionCheck(None, failure.code, failure.message)


def _request(model: str, code: str) -> CallRequest:
    image = ImageBlock(data=base64.b64encode(render(code)).decode("ascii"), media_type="image/png")
    return CallRequest(
        model=model, messages=(Message("user", (image, TextBlock(PROMPT))),), purpose="background")


def _blind() -> str:
    return ui("这个模型读不出图片里的字", "This model couldn't read the text in an image")


async def _collect(stream: Stream, request: CallRequest) -> tuple[str, LlmFailure | None]:
    parts: list[str] = []
    try:
        async for chunk in stream(request):
            if isinstance(chunk, TextDelta):
                parts.append(chunk.text)
            elif isinstance(chunk, Finish) and chunk.failure is not None:
                return "".join(parts), chunk.failure
    except LlmError as exc:
        return "".join(parts), exc.failure
    return "".join(parts), None
