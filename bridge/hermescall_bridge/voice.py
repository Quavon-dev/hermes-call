"""Spoken chat replies (M9 §9): chat text → something a TTS voice can read, and PCM → AAC in .m4a."""

import io
import re

import av
import numpy as np

# About two minutes of speech at Kokoro's pace.
MAX_SPOKEN_CHARS = 1800
MAX_SPOKEN_SECONDS = 150
MORE_IN_CHAT = "More in the chat."
BIT_RATE = 32_000
FRAME = 1024

_CODE_BLOCK = re.compile(r"```.*?(```|\Z)", re.DOTALL)
_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
_URL = re.compile(r"\b(?:https?://|www\.)\S+", re.IGNORECASE)
_LINE_PREFIX = re.compile(r"^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)")
_UNDERSCORES = re.compile(r"_{2,}")
_EMPHASIS = re.compile(r"\*+|~~|`+|(?<!\w)_|_(?!\w)")
# Emoji and pictographs (Kokoro reads them out as names or noise).
_SYMBOLS = re.compile("[\U0001f000-\U0001faff☀-➿️‍]")
_SPACE_BEFORE_PUNCT = re.compile(r"\s+([.,!?;:])")
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


def _clean_line(line: str) -> str:
    line = _LINE_PREFIX.sub("", line)
    # Runs of underscores collapse first, so the emphasis pattern never backtracks over long runs.
    line = _EMPHASIS.sub("", _UNDERSCORES.sub("_", line.replace("|", " ")))
    line = _SYMBOLS.sub("", line)
    line = re.sub(r"[ \t]+", " ", line)
    return _SPACE_BEFORE_PUNCT.sub(r"\1", line).strip()


def _cap(paragraphs: list[str], limit: int) -> str:
    """The first paragraphs (or sentences, or words) that fit, then a pointer to the chat."""
    kept: list[str] = []
    for paragraph in paragraphs:
        candidate = "\n\n".join([*kept, paragraph])
        if len(candidate) > limit:
            break
        kept.append(paragraph)
    if kept:
        return "\n\n".join(kept) + "\n\n" + MORE_IN_CHAT
    sentences: list[str] = []
    for sentence in _SENTENCE_END.split(paragraphs[0]):
        if len(" ".join([*sentences, sentence])) > limit:
            break
        sentences.append(sentence)
    head = " ".join(sentences) or paragraphs[0][:limit].rsplit(" ", 1)[0]
    return f"{head} {MORE_IN_CHAT}"


def speech_text(text: str, limit: int = MAX_SPOKEN_CHARS) -> str:
    """Markdown-ish chat text → plain sentences: no code blocks, URLs, markers or emoji; ≤ `limit` chars."""
    text = _CODE_BLOCK.sub("", text)
    text = _URL.sub("", _LINK.sub(r"\1", text))
    lines = [_clean_line(line) for line in text.splitlines()]
    paragraphs, current = [], []
    for line in [*lines, ""]:
        if line:
            current.append(line)
        elif current:
            paragraphs.append("\n".join(current))
            current = []
    spoken = "\n\n".join(paragraphs)
    if len(spoken) <= limit:
        return spoken
    return _cap(paragraphs, limit)


def encode_voice(pcm: bytes, rate: int = 24_000) -> bytes:
    """16-bit mono PCM → AAC-LC (≈ 32 kbit/s) in an MP4 (.m4a) container, the format the app records."""
    samples = np.frombuffer(pcm[: len(pcm) - len(pcm) % 2], dtype="<i2").astype(np.float32) / 32768.0
    samples = samples[: MAX_SPOKEN_SECONDS * rate]
    out = io.BytesIO()
    with av.open(out, "w", format="mp4") as container:
        stream = container.add_stream("aac", rate=rate)
        stream.bit_rate = BIT_RATE
        stream.layout = "mono"
        for start in range(0, len(samples), FRAME):
            chunk = samples[start : start + FRAME]
            frame = av.AudioFrame.from_ndarray(chunk.reshape(1, -1), format="fltp", layout="mono")
            frame.sample_rate = rate
            frame.pts = start
            for packet in stream.encode(frame):
                container.mux(packet)
        for packet in stream.encode(None):
            container.mux(packet)
    return out.getvalue()
