"""Turns streamed LLM text into speakable chunks."""

import re

_MARKDOWN = re.compile(r"```.*?```|`|\*\*?|__?|~~|^#+\s*|^\s*[-*+]\s+|^\s*\d+\.\s+|\[([^\]]*)\]\([^)]*\)", re.S | re.M)
_URL = re.compile(r"https?://\S+")
_SENTENCE_END = re.compile(r"[.!?…](?:[\"')\]]*)\s+|\n+")
_CLAUSE_END = re.compile(r"[,;:—–](?:\s+)")
FIRST_CHUNK_MIN_WORDS = 2
FIRST_CHUNK_MAX_WORDS = 6
MAX_CHUNK_CHARS = 220


def speakable(text: str) -> str:
    text = _MARKDOWN.sub(lambda m: m.group(1) or "", text)
    text = _URL.sub("a link", text)
    return " ".join(text.split())


class Chunker:
    """Feed deltas, get chunks. The first chunk of a reply ends at the first
    clause boundary so speech starts early; later chunks are whole sentences."""

    def __init__(self) -> None:
        self._buffer = ""
        self._first = True

    def feed(self, delta: str) -> list[str]:
        self._buffer += delta
        chunks = []
        while (cut := self._cut()) is not None:
            chunk, self._buffer = self._buffer[:cut], self._buffer[cut:]
            if spoken := speakable(chunk):
                chunks.append(spoken)
                self._first = False
        return chunks

    def flush(self) -> list[str]:
        rest, self._buffer = self._buffer, ""
        return [spoken] if (spoken := speakable(rest)) else []

    def _cut(self) -> int | None:
        patterns = (_SENTENCE_END, _CLAUSE_END) if self._first else (_SENTENCE_END,)
        for pattern in patterns:
            for match in pattern.finditer(self._buffer):
                if len(self._buffer[: match.end()].split()) >= FIRST_CHUNK_MIN_WORDS or pattern is _SENTENCE_END:
                    return match.end()
        if self._first and len(self._buffer.split()) > FIRST_CHUNK_MAX_WORDS:
            words = list(re.finditer(r"\S+", self._buffer))
            return words[FIRST_CHUNK_MAX_WORDS - 1].end()
        if len(self._buffer) > MAX_CHUNK_CHARS:
            space = self._buffer.rfind(" ", 0, MAX_CHUNK_CHARS)
            return space if space > 0 else MAX_CHUNK_CHARS
        return None
