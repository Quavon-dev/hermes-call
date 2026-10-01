# SPDX-License-Identifier: MIT
"""A call that survives a network handover (C1).

aiortc has no ICE restart, so when the phone's network changes it sends a new offer for the **same**
call id and the bridge builds a new peer connection. What belongs to the call stays: the conversation
(Hermes session, transcript, turn state) keeps reading `InboundAudio`, which moves on to the new
connection's track, and keeps writing the one `SpeechTrack`, which each connection reads through its
own `ForwardTrack` (aiortc stops a sender's track when its connection closes).
"""

import asyncio
from collections.abc import AsyncIterator

import av
import numpy as np
from aiortc import MediaStreamTrack

from .audio import SpeechTrack, read_16k

# How long a call may be without media (network change) before the bridge gives up.
RESUME_WINDOW = 20.0
RESUME_CAP = "call_resume"
# `hangup.why` when the bridge gave up waiting for the phone to come back.
CONNECTION_LOST = "connection_lost"


class ForwardTrack(MediaStreamTrack):
    """One peer connection's view of the call's speech track; stopping it leaves the speech track alive."""

    kind = "audio"

    def __init__(self, source: SpeechTrack) -> None:
        super().__init__()
        self._source = source
        source.resync()

    async def recv(self) -> av.AudioFrame:
        return await self._source.recv()


class InboundAudio:
    """The phone's audio across connections. `resumable`: when a track ends, wait for the next one
    (`attach`) instead of ending; `close` ends it for good."""

    def __init__(self, resumable: bool) -> None:
        self.resumable = resumable
        self._tracks: asyncio.Queue[MediaStreamTrack | None] = asyncio.Queue()

    def attach(self, track: MediaStreamTrack) -> None:
        self._tracks.put_nowait(track)

    def close(self) -> None:
        self._tracks.put_nowait(None)

    async def blocks(self) -> AsyncIterator[np.ndarray]:
        while (track := await self._tracks.get()) is not None:
            async for block in read_16k(track):
                yield block
            if not self.resumable:
                return
