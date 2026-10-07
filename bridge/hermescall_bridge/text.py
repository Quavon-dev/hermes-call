"""Turns streamed LLM text into speakable chunks."""

import re

_MARKDOWN = re.compile(r"```.*?```|`|\*\*?|__?|~~|^#+\s*|^\s*[-*+]\s+|^\s*\d+\.\s+|\[([^\]]*)\]\([^)]*\)", re.S | re.M)
_URL = re.compile(r"https?://\S+")
_SENTENCE_END = re.compile(r"[.!?…](?:[\"')\]]*)\s+|\n+")
_CLAUSE_END = re.compile(r"[,;:—–](?:\s+)")
# A period that does not end a sentence: "am 3. Oktober", "Dr. Schneider", "z. B.", "J. Smith".
_NOT_AN_END = re.compile(
    r"(?:\b\d{1,4}|\b[A-ZÄÖÜa-zäöü]|\b(?:Dr|Prof|Hr|Fr|Nr|Str|St|bzw|ca|vgl|evtl|ggf|inkl|zzgl|Mr|Mrs|Ms|Jr|Sr|vs|etc|No))\.$"
)
_JOINERS = frozenset(
    "und oder aber denn sondern weil dass ob wenn als damit sodass bevor nachdem während "
    "and or but because so that if when while before after".split()
)
FIRST_CHUNK_MIN_WORDS = 2
FIRST_CHUNK_SOFT_WORDS = 8
FIRST_CHUNK_MAX_WORDS = 14
MAX_CHUNK_CHARS = 220


def speakable(text: str, link: str = "a link") -> str:
    text = _MARKDOWN.sub(lambda m: m.group(1) or "", text)
    text = _URL.sub(link, text)
    return " ".join(text.split())


class Chunker:
    """Feed deltas, get chunks. The first chunk of a reply ends at the first
    clause boundary so speech starts early; later chunks are whole sentences."""

    def __init__(self, link: str = "a link") -> None:
        self._buffer = ""
        self._first = True
        self._link = link

    def feed(self, delta: str) -> list[str]:
        self._buffer += delta
        chunks = []
        while (cut := self._cut()) is not None:
            chunk, self._buffer = self._buffer[:cut], self._buffer[cut:]
            if spoken := speakable(chunk, self._link):
                chunks.append(spoken)
                self._first = False
        return chunks

    def flush(self) -> list[str]:
        rest, self._buffer = self._buffer, ""
        return [spoken] if (spoken := speakable(rest, self._link)) else []

    def _cut(self) -> int | None:
        patterns = (_SENTENCE_END, _CLAUSE_END) if self._first else (_SENTENCE_END,)
        for pattern in patterns:
            for match in pattern.finditer(self._buffer):
                head = self._buffer[: match.end()]
                if pattern is _SENTENCE_END and _NOT_AN_END.search(head.rstrip()):
                    continue
                if len(head.split()) >= FIRST_CHUNK_MIN_WORDS or pattern is _SENTENCE_END:
                    return match.end()
        if self._first and (cut := self._first_cut()) is not None:
            return cut
        if len(self._buffer) > MAX_CHUNK_CHARS:
            space = self._buffer.rfind(" ", 0, MAX_CHUNK_CHARS)
            return space if space > 0 else MAX_CHUNK_CHARS
        return None

    def _first_cut(self) -> int | None:
        """A long first sentence without punctuation: cut before a joining word, else after the limit."""
        words = list(re.finditer(r"\S+", self._buffer))
        if len(words) <= FIRST_CHUNK_SOFT_WORDS:
            return None
        complete = words[:-1]
        for index in range(len(complete) - 1, FIRST_CHUNK_MIN_WORDS, -1):
            if complete[index][0].lower().strip(",") in _JOINERS:
                return complete[index].start()
        if len(words) > FIRST_CHUNK_MAX_WORDS:
            return words[FIRST_CHUNK_MAX_WORDS - 1].end()
        return None
