# SPDX-License-Identifier: MIT
"""Per-language call defaults and the bridge's own spoken lines."""

import re
from dataclasses import dataclass

LANGUAGE = re.compile(r"[a-z]{2,3}")
# Kokoro voice names start with a language letter and a gender letter (af_heart, bm_george, dm_thorsten).
KOKORO_VOICE = re.compile(r"([a-z])[fm]_[a-z0-9_]+")
KOKORO_LETTERS = {
    "en": "ab",
    "es": "e",
    "fr": "f",
    "hi": "h",
    "it": "i",
    "ja": "j",
    "pt": "p",
    "zh": "z",
    "de": "d",
}


@dataclass(frozen=True)
class Phrases:
    name: str
    acknowledgement: str
    approval_prompt: str
    approval_denied: str
    fallback: str
    call_ending: str
    more_in_chat: str
    link: str


PHRASES = {
    "en": Phrases(
        "English",
        "One moment.",
        "I need your approval on your phone screen before I run that.",
        "Understood, I will not run it.",
        "Sorry, I couldn't reach {agent} just now.",
        "We have about a minute left on this call.",
        "More in the chat.",
        "a link",
    ),
    "de": Phrases(
        "German",
        "Einen Moment.",
        "Dafür brauche ich deine Freigabe auf dem Handy.",
        "Alles klar, dann führe ich das nicht aus.",
        "Entschuldige, ich erreiche {agent} gerade nicht.",
        "Wir haben noch etwa eine Minute.",
        "Mehr dazu im Chat.",
        "ein Link",
    ),
}
DEFAULT_VOICES = {"en": "bm_george", "de": "dm_thorsten"}
DEFAULT_SPEEDS = {"de": 1.05}
DEFAULT_TTS_URLS = {"de": "http://127.0.0.1:8881"}
DEFAULT_TTS_URL = "http://127.0.0.1:8880"


def phrases(language: str) -> Phrases:
    return PHRASES.get(language, PHRASES["en"])


def voice_language_mismatch(voice: str, language: str) -> str | None:
    """A Kokoro voice made for another language (bm_george reading German), or None."""
    match = KOKORO_VOICE.fullmatch(voice)
    letters = KOKORO_LETTERS.get(language)
    if match is None or letters is None or match[1] in letters:
        return None
    spoken = next((code for code, owned in KOKORO_LETTERS.items() if match[1] in owned), None)
    return f"tts.voice {voice} is a {spoken or 'non-' + language} Kokoro voice, but the call language is {language}"
